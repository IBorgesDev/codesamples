# 0004: One client remote, guarded and paced on both sides

## Context

The client is the attacker. A modified client can fire any remote, with any arguments, at any rate,
including the remotes meant for the server to fire. A vote costs a profile save and a MemoryStore
write, and totals are what every server shows, so a remote that trusts one value or costs too much
per call would let one player skew an event or drain the server's DataStore budget. Movement and
physics are out of scope here.

## Decision

**Expose one intent.** `live.vote(event_id, option)` is the only remote a client can use. Totals,
contributions and rewards are computed on the server; `live.progress`, `live.sync` and the
`live.mine` pushes only go to clients, and each has a server listener that drops anything a client
fires at it, so they cannot fill the invocation queue.

Before a vote changes anything, the server checks that the event exists, is a vote (not a counter),
lists the option, has not closed or ended, that the player's profile is loaded and has no vote in
flight, and that the server's DataStore write budget is at least 4. The ballot is saved in the profile
first; it only counts once the save landed, and a failed or thrown save rolls it back.

**Every handler goes through the guard** (`src/server/net/guard.luau`), in this order: a per-player
budget across all remotes (20/s, burst 40), the remote's own bucket (one vote per 30 s, burst 3),
the exact argument count, one validator per argument (strings of at most 48 and 32 bytes of valid
UTF-8; anything else is refused). The handler runs in `pcall`: an error is counted and answered as
a refusal.

**Strikes, then a kick.** Our client never sends a malformed payload, so 5 in 60 s kick the player.
300 calls refused for rate in 60 s also kick. `guard.on_violation` lets a game add its own response.

**The honest client never trips either.** `remote.to_server(pace)` declares the same bucket the
server enforces and the client drops a call locally when it is empty; the client also skips a vote
for the option it already has.

## Alternatives

- **Kick on the first violation.** One lost packet would cost an honest player the session.
- **A vote cooldown per event instead of a bucket.** Same cost bound, but a player who misclicks
  could not fix it for the whole cooldown; burst 3 allows that.
- **Client-side anti-tamper.** It does not stop someone from firing the remote.

## Consequences

- **Measured in Studio** with a client firing remotes directly (2026-11-17): votes for an unknown
  event, for a counter event and for an option not in the catalog, and 60 calls to server-to-client
  remotes with forged totals and rewards, changed nothing (the player's ballot and the event totals
  identical). 400 votes in a row were all refused for rate and kicked the player after 300. A client
  paced by the shared module sent 3 of 10 votes, and the server refused none.
- **A vote cannot outrun the budget.** At one per 30 s a player spends at most 2 profile saves a
  minute, below the 40 writes per player per minute a server gets, and the planner counts vote
  changes at that rate: `live_capacity.spec` shows 76M CCU still fits even if every player changes
  their vote every 30 s for the whole event.
- A new remote must be declared with its pace, wrapped in `guard.handler` with one validator per
  argument, and check everything it reads on the server. `guard.spec.luau` covers the guard itself.
