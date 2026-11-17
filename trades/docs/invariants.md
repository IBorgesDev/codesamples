# Trade invariants

Items have identity (one GUID each) and coins are integers, so every invariant below is a plain
check on stored data. `world:check()` (`tests/support/world.luau`) verifies all of them on the
durable state after a chaos run and a full recovery.

| | Invariant | How it is checked |
|---|---|---|
| **I1** | **Conservation.** Total coins and the set of item ids across all profiles (inventory and escrow) never change. | Every stored item is where the replay (I3) says it is, every expected item is stored somewhere, and each player's coins match the replay. |
| **I2** | **Uniqueness.** Each item id is in exactly one place. | No item id appears in two profiles. |
| **I3** | **Atomicity.** Once recovery has run, each record is either `committed` with both sides credited or `aborted` with both sides refunded. | No record is left `open`. Committed records are replayed in decision order from the starting inventories: every item a side gave must belong to that side at that point, and the replay must end exactly at the stored state. |
| **I4** | **No orphan.** Once recovery has run, no escrow is left. | No profile has an escrow entry. |
| **I5** | **Idempotence.** Running finalize or recovery again changes nothing. | After the checks, recovery runs three more times; records and profiles must be identical. During the run, messages are duplicated and sweeps repeat recovery all the time. |

## Why they hold

- An escrow only leaves through a **decided record** (`ledger.settle`), and `settle` does nothing
  when the escrow is already gone. That gives I5, and with I4 every hold ends in exactly one settle.
- A side votes only after a save containing its escrow has landed. So when the second vote commits
  the record, both escrows are durable: a crash on either side reloads the escrow, and recovery
  settles it from the record (I3).
- The record changes only through three pure transforms (`create`, `vote`, `abort`). `abort` cannot
  move a committed record, so the commit point is final. Both settles read the same record, so they
  agree (I1, I2).
- The opener saves its escrow **before** it creates the record and votes in that same write. So
  every record has a durable escrow behind it, and recovery of that escrow drives the record to a
  decision. An escrow whose record never got written becomes an aborted tombstone after
  `missing_record_grace`, and the tombstone makes a late create fail (I3, I4).
- A session that lost its lock cannot save (ProfileStore rejects it, and the fake does the same), so a
  stale server never overwrites the profile that recovery works on.

## Across servers

A cross-server trade ([decision 0003](0003-cross-server-trades-and-gifts.md)) adds a
shared session on MemoryStore in front of the same record, so I1–I5 still come from the record. The
session only decides *when* the record starts and lets each server see the other's progress:

- **One transaction per session.** The lock and `tx_id` are written in one `UpdateAsync` that
  refuses if `tx_id` is already set, and offer changes are refused from then on.
- **B never prepares early.** B holds its side only once the session says `opened`, which A writes
  after its record exists. Before that, B can only abort the record, and only after 25 s of silence.
- **Aborting cannot break a commit.** `abort` refuses a decided record, so B giving up after its own
  vote changes nothing, and a tombstone written for a record that never existed makes A's late create
  fail and refund A.
- **Losing the session loses nothing.** It holds no items. If it expires or a server dies, each
  escrow is still in its profile and recovery settles it from the record.

`trade_cross.spec.luau` drives both sides by polling alone against a fake coordinator built on the
real transform, including A dying after the lock, a late opener after B's abort, and an abort after
B's vote.

## Gifts

A gift has no record: the sender's profile holds the gift in an outbox until delivery, and the
receiver's profile remembers the highest gift number it credited per sender.

- **I1.** Debit and outbox entry are one mutation; credit and message removal land in one save. The
  outbox counts toward the sender's holdings until delivery confirms.
- **No credit without a durable debit.** A gift is sent only after a save containing its outbox entry
  has landed.
- **Exactly once.** Gifts are numbered per sender and delivered in order per receiver, stopping at
  the first failure for that receiver. A resend after a crash carries a number the receiver has
  already credited, so it is dropped.
- **Never dropped by the receiver's queue.** A gift is sent only after it holds a slot in the
  receiver's inbox ledger, which caps what waits for one receiver far below ProfileStore's queue
  size, and slots are freed only once a save holding the credit landed.

`trade_gift.spec.luau` replays 200 random runs of sends, failed and duplicated deliveries, and sender
crashes back to the last save, and checks conservation and an empty outbox each time. It also runs 40
rounds of 30 senders gifting one offline player whose queue drops the oldest above 40, with failed
sends and crashes on both sides, and checks that nothing was dropped and every coin arrived.

## Proof that the checks can fail

`trade_checker.spec.luau` breaks the protocol in three known ways (settle keeps the escrow, abort
overrides a commit, a save reports success without landing) and expects violations each time.
`trade_chaos.spec.luau` also requires at least a quarter of the trades to commit, so a change that
makes every trade abort fails too.

## Measured on the real DataStore

`TradeBenchmark = 10` in a Studio playtest on 2026-11-16 (ProfileStore on `Players_v1_studio`,
records on `Trades_v1_studio`):

| Measure | Result |
|---|---|
| Trades | 10 of 10 committed |
| Latency, full trade (both escrows saved, vote, both settlements saved) | p50 2.97 s, p95 3.33 s |
| DataStore work per trade | 4 profile saves, 4 record calls (create, read, vote, read) |
| Conservation | items 12 → 12, coins 1,000 → 1,000, no escrow left |

The latency is almost all ProfileStore saves (~0.7 s each, one after another). The last two are
settlements after the commit point, and they now run in the background (`ports.later`): the escrow
is already durable and recovery repeats a settlement that did not land. The chaos simulation drops
20% of those background saves and every invariant still holds. Measured again on 2026-11-16, with
the profiles idle before each trade: p50 **2.29 s**, p95 4.26 s until both players see the result
(was 2.97 s), and cross-server settlement p50 **3.90 s** (was 4.67 s).

With Studio API access turned off, the same benchmark left all 10 trades pending: every record write
failed, and items and coins were still conserved, with the escrows waiting for recovery.

### Across servers and gifts

`TradeCrossBenchmark = 10` and `GiftBenchmark = 5` in a Studio playtest on 2026-11-16. The two bench
profiles act as two logical servers (`loop_a`, `loop_b`) on the real MemoryStore, MessagingService
and DataStore:

| Measure | Result |
|---|---|
| Cross-server trades | 10 of 10 committed |
| Negotiation and settlement (create, offer, both accepts, lock, both escrows, vote, settlements) | p50 6.18 s, p95 6.58 s |
| Settlement only, from the lock | p50 4.67 s, p95 4.93 s |
| Work per trade | 10 MemoryStore calls, 4 record calls, 4 profile saves |
| `changed` hints on MessagingService | 10 of 10 delivered, p50 200 ms, p95 231 ms |
| Gifts | 5 of 5 credited, send to credit p50 1.29 s, p95 1.40 s |
| Conservation | items 12 → 12, coins 1,000 → 1,000, no escrow and no gift left in the outbox |

A gift sent through the game UI on the same day (user 2 has never joined this place) moved the item
and 7 coins out of the sender's saved profile and left exactly one gift message, seq 1, in the
receiver's ProfileStore queue; the sender's outbox was empty after its next save.

### Many players at once

`StressTest = true` runs four scenarios at the same time each, on the real DataStore, MemoryStore,
MessagingService and ProfileStore, with 12 test profiles as players (2026-11-16, two runs):

| Scenario | Run 1 | Run 2 |
|---|---|---|
| 6 trades started at the same instant | 4 committed, 2 aborted and refunded: the DataStore answered HTTP 500 for two profile keys, so their saves never landed | 6 committed, p50 3.30 s, p95 3.65 s |
| The same item offered in 2 trades at the same instant | 1 committed, 1 refused | 1 committed, 1 refused (`items`) |
| One player in 3 trades at the same instant, different items | 3 committed | 3 committed |
| 4 cross-server trades at once, one with 3 servers racing to lock it | 4 committed, locked once | 4 committed, locked once, p50 5.5 s |
| 6 senders x 2 gifts to one player at once, every message sent twice | 12 credited once each, receiver +12 coins | same, all credited in 18.5 s |
| Conservation over the 12 profiles after each run | 72 items and 6,000 coins kept, no duplicate item, no escrow or outbox left | 78 items and 6,007 coins kept, same |

The first run is the more useful one: Roblox's DataStore failed for real in the middle of it, the
two trades it hit aborted with their items back where they started, and nothing was lost or
created. A client firing 600 trade, gift and vote requests in a burst only got through the burst
allowance of its rate limiter; the rest were dropped before validation and the server kept serving.

Settlement takes about 1.7 s more than on one server: the same 4 profile saves and 4 record calls,
plus the lock, `opened`, outcome and session reads on MemoryStore, each a few hundred milliseconds in
Studio. In a live game the countdown already hides the lock, and the hints arrive in about 0.2 s, so
neither side waits for the 2 s poll.
