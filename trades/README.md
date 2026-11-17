# Trades

Two-way trades between players where no item or coin is ever lost or duplicated, whatever crashes
and whenever. Works on one server, across servers, and for gifts to players who are offline.

## How it works

- Each player's offer moves into an **escrow** inside their own profile, and the profile is saved.
- One **record** per trade, in its own DataStore key, decides the result. The second player's
  accept is one `UpdateAsync` on that key: that is the commit, and the only atomic step needed.
- Each side then **settles** from the record: its escrow becomes the other side's offer, or goes
  back to its owner. Settling twice changes nothing, so a crashed trade finishes when the profile
  loads again.
- **Across servers**, a shared MemoryStore session coordinates the two servers. **Gifts** go into an
  outbox in the sender's profile and are delivered with ProfileStore messages, numbered so a resend
  is never credited twice, after taking a slot in the receiver's inbox so its message queue never
  overflows.

More in [docs/protocol.md](docs/protocol.md), [docs/invariants.md](docs/invariants.md) and
[docs/0003-cross-server-trades-and-gifts.md](docs/0003-cross-server-trades-and-gifts.md).

## Run it

```bash
mise install
mise run install
mise run serve
```

Then Connect in the Studio Rojo plugin (port 34875) and turn on **Enable Studio Access to API
Services** (Experience Settings → Security). Every playtest runs the specs first and prints
`[tests] all N passed`. In game, the Trade and Gift buttons open the UI.

## Studio test hooks

Attributes on `ServerScriptService`:

| Attribute | Effect |
|---|---|
| `TradeSeed = true` | Players who join with no items get 6 items and 500 coins |
| `TradeBenchmark = N` | Runs N real trades between two test profiles and prints latency and saves per trade |
| `TradeCrossBenchmark = N` | Runs N cross-server trades between two logical servers on the real services |
| `GiftBenchmark = N` | Sends N gifts through ProfileStore messages and prints the time until credited |
| `StressTest = true` | Runs many trades, cross-server trades and gifts at once with 12 test profiles and checks that nothing was lost or duplicated |

## Layout

| Folder | Contents |
|---|---|
| `src/server/trade/` | The trade rules (`protocol`, `record`, `ledger`, `recovery`, `negotiation`, `cross`, `gift`, `inbox`) and their Roblox adapters |
| `src/server/` | Remote validation and rate limits (`net/`), player profiles (`data/`), Studio tools (`dev/`) |
| `src/shared/` | Remotes, config and utilities |
| `src/client/` | Trade and gift windows |
| `tests/` | Specs, including a crash simulation of 1,000 trades per seed |
| `docs/` | Protocol, invariants, decisions and the Roblox limits they rely on |
