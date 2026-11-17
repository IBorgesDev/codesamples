# 0004: Remotes as the only attack surface, guarded and paced on both sides

## Context

The client is the attacker. A modified client can fire any remote, with any arguments, at any rate,
including the remotes meant for the server to fire. Trades move items and coins between profiles,
so a remote that trusts one value, skips one check or costs too much per call becomes a duplication
exploit or a way to stall saves for a whole server. Movement and physics are out of scope here.

## Decision

**Expose only intents.** Seven client remotes, each acting only on the caller's own state, resolved
from `player.UserId`; the client never names a trade, a record or another player's item.

| Remote | Arguments | Server checks before anything changes |
|---|---|---|
| `trade.invite` | user id | not busy, 3 s cooldown, not self, target loaded and free; one pending invite per sender per target, at most 5 per target, never overwritten |
| `trade.answer` | user id, boolean | an unexpired invite from that sender exists; for cross-server, one new session per 10 s |
| `trade.offer_item` | item GUID, boolean | caller is negotiating; the item is in the caller's profile now |
| `trade.offer_coins` | integer 0..1e9 | caller is negotiating; the caller has the coins now |
| `trade.accept` | offer version | the exact version both sides see; not within 3 s of the other side's last change |
| `trade.cancel` | none | caller is negotiating |
| `trade.gift` | user id, integer coins, up to 12 item GUIDs | not self, the receiver has a profile, DataStore budget of at least 12, outbox below 32, every item owned and listed once |

Ownership and balance are checked again when either side locks (`ledger.covers`), so an offer that
became false meanwhile aborts the trade and refunds both sides. Server-to-client remotes
(`trade.invited`, the `view` and `inventory` pushes) get a server listener that drops anything a
client fires at them, so they cannot fill the invocation queue.

**Every handler goes through the guard** (`src/server/net/guard.luau`), in this order: a per-player
budget across all remotes (20/s, burst 40), the remote's own bucket, the exact argument count, one
validator per argument (NaN, infinities, fractions, out-of-range numbers, invalid UTF-8, oversized
strings, sparse or oversized arrays and wrong types are all refused). The handler runs in `pcall`:
an error is counted and answered as a refusal, and never reaches the client.

**Strikes, then a kick.** Our client never sends a malformed payload, so 5 in 60 s kick the player.
300 calls refused for rate in 60 s also kick. `guard.on_violation` lets a game add its own response
(a log, a ban list) without touching the guard.

**The honest client never trips either.** `remote.to_server(pace)` declares the same bucket the
server enforces, and the client drops a call locally when that bucket or the global one is empty,
so a player mashing a button sends at most what the server accepts. The client store also clamps
every value to what the validators accept (coins to the balance and the per-side maximum, at most
12 items, positive user ids).

**Every call has a bounded cost.**

- Gifts: one per 15 s per player (burst 3). Refused when the server's DataStore write budget is
  under 12, three times what a trade needs, so gift spam cannot stall trades or saves. Gifts only go
  to a user id that has a profile (one `GetAsync`, a hit is cached), so no coins or items are burned into
  ids that never played.
- Cross-server operations: one per 3 s per player (burst 6) on top of the trade bucket. A change
  that changes nothing writes nothing. A closed session expires after 60 s instead of 15 minutes.

**No griefing through timing.** Accepting within 3 s of the other side's last change is refused
(the Accept button counts it down), so an offer swapped just before the click is never accepted. A
trade that B aborts releases A's escrow at once instead of at the next 30 s sweep.

## Alternatives

- **Kick on the first violation.** Simpler, but one lost packet or a client that lags behind a
  version change would cost an honest player the session. Five malformed payloads cannot happen by
  accident.
- **Persisted strikes or bans.** Useful against repeat offenders, but it is game policy, not
  infrastructure; `guard.on_violation` is the hook for it.
- **Client-side anti-tamper.** It does not stop someone from firing remotes, which is the only way
  in. Everything that matters is decided on the server.
- **One shared bucket for every remote.** A cheap remote would starve an expensive one. Each remote
  has its own bucket and the global one bounds the sum.

## Consequences

- **Measured in Studio** with a client firing remotes directly (2026-11-17): 11 well-formed but
  illegitimate calls (inviting and gifting oneself, gifting an id that never played, offering an
  item not owned, offering 1e9 coins, accepting and cancelling with no trade) and 60 calls to
  server-to-client remotes changed nothing (inventory identical, no view pushed). 4 malformed
  payloads were refused and counted, and the 5th kicked the player. A client paced by the shared
  module sent 20 of 100 cancels and 3 of 10 gifts, and the server refused none. In the trade
  window, Accept counts the wait down and a click during it sends nothing; the first click after it
  sends the accept with the current version. The real-service benchmarks and `StressTest` still
  commit and conserve everything ([decision 0003](0003-cross-server-trades-and-gifts.md)).
- **Abuse fits the quotas.** `trade_capacity.spec` adds players who open a cross-server session
  every 10 s and change it every 3 s for good: at 76M CCU the design still fits with 1.4% of all
  players doing it at once.
- Studio's local test players have negative user ids, which the validators refuse, so local
  multi-client sessions cannot trade or gift; real accounts are unaffected.
- A new remote must be declared with its pace, wrapped in `guard.handler` with one validator per
  argument, and check ownership on the server. `guard.spec.luau` covers the guard itself.
