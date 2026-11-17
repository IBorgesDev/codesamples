# Analytics

Sends typed events from game servers (sessions, trades, purchases, live event activity) into
ClickHouse, under a minute behind, with each batch stored exactly once.

## How it works

- `schema/events.json` lists every event and its props. The game and the service both validate
  against it, and `schema/fixtures.json` holds cases both sides must agree on.
- The game SDK (`analytics.track(name, player, props)`) buffers events and sends one numbered batch
  every 10 s. A failed batch is retried with the same number, so the service drops the duplicate.
  Nothing on the gameplay path waits on HTTP.
- The ingest service puts each batch on a Redis stream once; a worker inserts it into ClickHouse
  with a deduplication token and acknowledges only after the insert.
- When the service is down, the game keeps the newest 5,000 events and reports how many it dropped.

More in [docs/0001-analytics-pipeline.md](docs/0001-analytics-pipeline.md).

## Run it

```bash
mise install
mise run install
mise run serve
```

Then Connect in the Studio Rojo plugin (port 34875) and turn on **Allow HTTP Requests** (Experience
Settings → Security). Every playtest runs the specs first and prints `[tests] all N passed`.

To store events: `mise run up` starts Redis, ClickHouse, the ingest and the worker with Docker,
`mise run tunnel` gives the ingest a public URL, and the Local Secrets `analytics_url` and
`analytics_token` (`ANALYTICS_SERVER_TOKEN` from `infra/.env`) point the game at it. Without them the
SDK counts events and discards them.
`mise run test-service` and `mise run load` test the service.

## Studio test hooks

Attributes on `ServerScriptService`:

| Attribute | Effect |
|---|---|
| `AnalyticsDemo = true` | Tracks sample trades, gifts, contributions, votes and purchases for the players in the server |
| `AnalyticsEcho = true` | Prints each batch instead of sending it |

## Layout

| Folder | Contents |
|---|---|
| `src/server/analytics/` | The SDK: `buffer`, `validate`, `transport`, `service` |
| `src/server/` | HTTP budget and circuit breaker (`net/`), Studio tools (`dev/`) |
| `schema/` | The event contract shared by the game and the service |
| `service/` | Ingest, ClickHouse worker and stats API (TypeScript) |
| `clickhouse/` | Tables and the per-minute view |
| `tests/`, `load/`, `infra/` | SDK specs, the k6 load test and the Docker setup |
| `docs/` | Design and the Roblox limits it relies on |
