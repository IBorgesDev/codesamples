# 0003: Cross-server trades through a shared session on MemoryStore, gifts through ProfileStore messages

## Context

Same-server trades run the record protocol in [the trade invariants](invariants.md): escrow
in each profile, one durable record, the second vote as the commit point. Two cases have no server
that holds both profiles:

- **Players on different servers** (friends apart, trading hubs). ProfileStore locks each profile to
  the server its player is on, so each side's server can only touch its own player.
- **Gifts to offline players.** There is no second session at all.

Both must keep I1–I5 (conservation, uniqueness, atomicity, no orphan, idempotence) through server
crashes, lost messages and retries, at the largest Roblox peaks (25.8M CCU, about 3.2M servers).

## Decision

**Cross-server trades: one shared session per trade, the same record protocol for the commit.**

- **Presence.** Key `u:<user>` holds the server id, with a TTL. Set when the profile loads, refreshed
  every 10 minutes, cleared on leave with an `UpdateAsync` that only clears it if it still names this
  server (a player who already moved keeps the newer value).
- **Invite.** The inviter's server reads the target's presence and sends an `invite` on the
  MessagingService topic `trade:<server id>`. If the target accepts, the target's server creates the
  session key `s:<session>` and sends `accepted` back. The inviter's server checks that it really
  sent that invite; if not, it cancels the session.
- **Negotiation.** The session key holds the same `negotiation.Session` as a same-server trade and
  changes only through `UpdateAsync` transforms that run `negotiation.apply` on a copy. Every change
  bumps `rev`, and a server ignores reads older than what it already has.
- **Sync.** Each server polls its sessions every 2 s. After every change it sends a `changed` hint to
  the other server, which polls at once. A lost hint costs one poll interval, nothing more.
- **Commit.** The inviter's server (A) locks the session and writes `tx_id` in one `UpdateAsync`, so
  one session has exactly one transaction. Then it runs `protocol.open` (hold, save, create the
  record with its vote) and marks the session `opened`. B prepares only after `opened`, so it never
  takes a record that is not written yet for a missing one. The outcome is copied into the session
  once.
- **A goes silent.** If the session stays locked but not opened for `persist_timeout + lock_grace`
  (25 s), B aborts the record. On a missing record that writes a tombstone, so if A's server was only
  slow, its create fails and it refunds itself. If B already voted, the abort is refused and the
  commit stands.
- **Spread.** Keys are hashed over 256 hash maps so no partition gets hot.

**Gifts: an outbox in the sender's profile, ProfileStore messages, a per-sender sequence.**

- The sender's debit and the outbox entry are one mutation of the sender's profile. The gift is
  delivered only after a save containing that entry has landed, so a crash can never undo a debit
  whose gift was already credited.
- Delivery is `ProfileStore:MessageAsync`, an `UpdateAsync` on the receiver's profile key that works
  whether the receiver is online, offline, or has never joined.
- Each sender numbers its gifts (`gift_seq`). The receiver keeps the highest number credited per
  sender and only credits higher ones; the credit and the removal of the message land in the same
  save. The sender delivers in sequence order per receiver and stops at the first failure for that
  receiver, so a resend after a crash is always recognized.

## Alternatives

- **MessagingService as the source of truth.** Delivery is best effort and unordered, so the two
  servers could disagree on the offer. It only carries hints here.
- **Teleport both players to one server.** Costs a teleport for both, and a player who fails to
  arrive still leaves a half-done trade. The shared session works wherever they are.
- **One coordinator hash map.** At 25.8M CCU, presence and sessions need about 38M RU per minute;
  at the ~20 partitions × ~30,000 RU per minute measured and estimated for one map, it would throttle.
  1,024 maps carry about 37,000 RU per minute each (108,000 at 76M).
- **A time-limited "seen" list for gifts.** A sender who crashed after delivering and came back after
  the time limit would be credited twice. The sequence needs no time limit.
- **A separate escrow key per gift.** Two more writes per gift and its own recovery. The outbox in the
  sender's profile is atomic with the debit at no extra cost.

## Consequences

- **Cost.** About 121 RU per cross-server trade (1 create, ~15 `UpdateAsync`, ~90 polls over 1.5
  minutes) plus presence (3 RU per join, 1 RU per online player every 10 minutes). At a 25.8M
  CCU peak, with 1% of players starting a cross-server trade every minute: 1.2% of the
  RU quota, 37,000 RU per minute on the busiest map, 4.1M MessagingService deliveries per minute
  against a limit of 646M (`trade_capacity.spec`).
- **Measured in Studio** on the real MemoryStore, MessagingService and DataStore: 10 of 10
  cross-server trades committed, settlement p50 4.67 s (1.7 s more than on one server), hints
  delivered in about 0.2 s, gifts credited in about 1.3 s, everything conserved
  ([invariants](invariants.md#across-servers-and-gifts)). Re-run on 2026-11-17: 20 of 20
  cross-server trades committed (settlement p50 4.27 s, hints p50 0.2 s), 20 trades on one server
  (p50 2.25 s), 20 gifts (p50 1.32 s), and `StressTest` (6 trades at once, one item in two trades,
  4 cross-server trades with 3 servers racing for one lock, 12 gifts each sent twice) conserved
  every item and coin.
- **Ceiling.** At the same load the design fits up to 210M CCU with 4 or 8 players per server
  (`trade_capacity.spec` searches it), so 76M uses 108,000 RU/min on the busiest map. The first
  limit is the busiest of the 1,024 coordinator maps reaching 300,000 RU/min (half of 20 partitions
  × 30,000); with the earlier 256 maps it was 52.6M. At 5% of players per minute the ceiling is
  ~49M. Maps cost nothing until used, and 5 cross-server trades on the real services committed with
  1,024 (settlement p50 4.28 s). Every server must use the same count, since a key's map is its
  hash modulo the count: change it with a migration to the latest version, not a rolling update.
- **Clock.** The countdown uses wall clock (`DateTime.now()`) compared across servers. A few seconds
  of skew only shifts when the lock happens.
- **ProfileStore's message queue holds 1,000 messages.** Beyond that it drops the oldest
  (`MAX_MESSAGE_QUEUE` in ProfileStore 1.0.3). A player offline long enough to receive over 1,000
  gifts would lose the oldest. Senders are rate-limited and keep at most 32 pending gifts each, but
  nothing caps one receiver across many senders; production would count a receiver's pending gifts in
  MemoryStore before sending.
- **The receiver keeps one number per distinct sender, forever.** It grows with the number of people
  who ever gifted that player, not with the number of gifts.
