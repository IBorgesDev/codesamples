# Live events

A global event that players on every server contribute to and every server shows within seconds: a
world fishing goal, a vote for the next boss. No contribution is lost or counted twice.

## How it works

- Each server keeps its own running total and sends that total, never a delta. The store keeps the
  newest value per server, so retries and duplicates cannot double count.
- On **MemoryStore**, servers write into shard keys. A few leader servers read the shards by key, sum
  them and broadcast the total. Nothing is ever listed (listing a hash map costs ~350 RU and ~5 s).
- On **Redis** (`service/`), one Lua script keeps the maximum per server, for games that prefer
  their own backend.
- One vote per player, counted exactly once even through crashes (the vote is the player's own
  entry, saved in the profile and republished until it lands), goal rewards granted once, and totals
  archived on DataStore so a MemoryStore reset never shows a lower number.
- The vote is the only remote a client can use. The server checks every argument and the event
  before anything changes, rate-limits it, and kicks a client that sends malformed payloads or
  floods; the honest client paces itself with the same limits
  ([docs/0004-remote-security.md](docs/0004-remote-security.md)).

The capacity model in `tests/live_capacity.spec.luau` fits 76M CCU with every player voting, in 6–12% of
the MemoryStore quota.
More in [docs/0003-global-live-events.md](docs/0003-global-live-events.md).

## Run it

```bash
mise install
mise run install
mise run serve
```

Then Connect in the Studio Rojo plugin (port 34875) and turn on **Enable Studio Access to API
Services** (Experience Settings → Security). Every playtest runs the specs first and prints
`[tests] all N passed`. The panel at the top right shows the world goal and the vote.

For the Redis backend: `mise run up` starts Redis and the service with Docker, `mise run tunnel` gives
it a public URL, and the Local Secrets `events_url` and `events_token` (`EVENTS_SERVER_TOKEN` from
`infra/.env`) point the game at it. `mise run test-service`, `mise run load` and `mise run stress` test the service.

## Studio test hooks

Attributes on `ServerScriptService`:

| Attribute | Effect |
|---|---|
| `LiveEventDemo = true` | The server catches random fish every second and logs the world total every 5 s |
| `LiveEventBackend = "http"` | Uses the Redis service instead of MemoryStore |
| `LiveEventDisabled = true` | The live event service does not start |
| `StressTest = true` | 12 logical servers publish to one event at once on the real MemoryStore while 24 players vote, change and republish old ballots out of order; the final totals are checked |

## Layout

| Folder | Contents |
|---|---|
| `src/server/live_event/` | `counter`, `aggregator`, `planner` (capacity model), `ballot`, `reward`, `archive`, the MemoryStore and HTTP backends |
| `src/server/` | Remote validation and rate limits (`net/`), player profiles (`data/`), Studio tools (`dev/`) |
| `src/shared/` | Remotes, config and the event catalog |
| `src/client/` | The progress and vote panel |
| `tests/` | Specs, including a 300-server simulation with crashes |
| `service/`, `load/`, `infra/` | The Redis service (TypeScript), its k6 load and stress tests and Docker setup |
| `docs/` | Design, numbers and the Roblox limits they rely on |
