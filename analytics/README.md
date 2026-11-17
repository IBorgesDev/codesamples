# Analytics

Code that sends game events (sessions, trades, purchases, live event activity) from Roblox servers
to ClickHouse: a small SDK in the game and an ingest service with a worker in `service/`.

It solves losing or duplicating data: requests fail and get retried, servers die, the service goes
down, and each batch is still stored exactly once, without the game ever waiting on HTTP.

## Run

```bash
mise install
mise run serve
```

Connect the Rojo plugin in Studio (port 34875) and allow HTTP requests. `mise run up` starts Redis,
ClickHouse, the ingest and the worker with Docker.
