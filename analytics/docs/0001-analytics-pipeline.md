# 0001: Analytics as typed batches with a per-server sequence, Redis Streams, then ClickHouse

## Context

Game servers produce the events a studio steers by (sessions, trades, gifts, live event activity),
and a dashboard should show them within a minute. At 7.56M CCU that is ~945,000 servers;
at 25.8M CCU, ~3.2M. A server can call HttpService 500 times a minute in total, shared
with everything else it does ([platform-limits.md](platform-limits.md)); requests fail, time out and get retried;
servers die with events in memory.

## Decision

**One schema, two readers.** `schema/events.json` lists every event, its props and their
types, plus limits. Rojo maps `schema/` into the game, so the SDK validates against the same file the
service loads, and `fixtures.json` holds valid and invalid events that the specs on both sides must
agree on. An event that does not match is dropped and counted where it is produced, not discovered
in a broken query weeks later.

**Game SDK** (`src/server/analytics/`):

- `analytics.track(name, player, props)` validates, applies the event's sample rate (a sampled event
  carries `weight = 1 / rate`, so counts scale back), and appends to a bounded buffer. Nothing on the
  gameplay path waits on HTTP.
- Every 10 s, or at 500 events, the buffer cuts one batch and gives it the server's next sequence
  number. A failed batch is retried **with the same number** until the service acknowledges it, so
  `(server_id, batch_seq)` is an idempotency key: a retry after a lost acknowledgement is a duplicate
  the service drops. The service keeps the key for an hour, so the SDK gives a batch up after 50
  minutes of failures instead of risking a double insert.
- When the service is down the buffer keeps the newest 5,000 events and drops the oldest, and the
  next batch reports how many were dropped.
- Requests go through the server's HTTP budget (240 of the 500 per minute), a circuit breaker and
  backoff with full jitter that honors `Retry-After`. 400 and 413 drop the batch (it can never
  succeed); everything else retries.
- `RequestAsync`, not `PostAsync`: it returns status codes and headers. `PostAsync` can gzip but hides
  them in error strings. The service accepts gzip bodies anyway, for clients that can send them.

**Service** (`service/`, Fastify): validates every event again, then one Redis Lua script
checks the dedupe key, appends the batch to a stream and only then sets the key, so a failed append
can never leave a batch marked as seen without being stored. Streams are sharded by server id, with
each dedupe key in its stream's hash slot so the script stays valid on Redis Cluster. A duplicate
answers with the original counts. Events more than a day old or 5 minutes in the future are
rejected, so one insert never touches many day partitions. When consumer lag plus pending entries
pass 20,000, ingest answers 503 with `Retry-After` and the game backs off; streams are trimmed at
twice that, so trimming only ever removes acknowledged entries (checked at startup).

**Worker**: reads the streams in a consumer group, inserts into ClickHouse with a deduplication token
built from the stream key and entry ids, and acknowledges only after the insert. On restart a worker
first replays its own pending entries, which rebuilds the same group and the same token. Entries left
by a dead consumer are taken back after 60 s idle, one consumer at a time: `XPENDING` finds a dead
consumer, a second `XPENDING` lists that consumer's entries, and `XCLAIM` takes exactly those. That is
the group it read, in the same order, so the token matches an insert it may already have made, even
when several workers die at once (`reclaim.test.ts`). `XAUTOCLAIM` was not used for this: it scans
idle entries across all consumers, so it can merge two dead consumers' groups into one with a new
token.

**ClickHouse**: raw events in a MergeTree for 90 days, and a materialized view with weighted counts
and unique users per minute, which the dashboard's query API reads.

**Dashboard** (`dashboard/`, Next.js): server-side route handlers call the query API with a read token that
never reaches the browser. Without a configured service it serves generated demo data, labelled as
such.

## Alternatives

- **Send events one by one, or straight to ClickHouse.** At 945,000 servers that is millions of
  requests per minute and many tiny inserts, which ClickHouse handles badly. Batching in the game and
  again in the worker keeps both in range.
- **A delta-free design (per-server cumulative counters).** Analytics is an append-only log, not a counter; an
  idempotency key per batch is the simpler exactly-once.
- **Kafka.** More throughput headroom, much more to run. Redis Streams with consumer groups give the
  same at-least-once delivery and replay at this repo's scale, and the shard key lets it grow.
- **Roblox's built-in AnalyticsService.** No raw access and no custom queries, so it cannot feed this
  dashboard.

## Consequences

- **Ingest rate.** One request per server every 10 s: ~95,000 requests per second at 7.56M
  CCU, ~320,000 at 25.8M. Ingest instances scale horizontally and the streams
  are sharded; past that, the flush interval is the lever (30 s cuts the rate to a third and costs
  20 s of freshness).
- **Exactly once, end to end, as long as the dedupe key outlives the retries**: the key lives an
  hour and the game stops retrying a batch after 50 minutes.
- **Loss is bounded and visible**: a server crash loses at most one flush interval plus whatever was
  waiting while the service was down, and buffer drops are reported in the next batch.
- **The one case the token cannot cover**: if stream trimming ever removed an entry that a dead
  consumer still had pending, the reclaimed group would be smaller and its token new. Backpressure
  stops appends at 20,000 unacknowledged entries and streams trim at 40,000, so this needs the
  approximate trim to overshoot by half.
- **`user_id` must be non-negative** (a `UInt64` column). Studio's local test players have negative
  ids, so their events are rejected in local server tests; real accounts are fine.
- **`clickhouse/init.sql` runs only on an empty volume.** An existing `clickhouse-data` volume
  needs `docker compose down -v` (which also wipes Redis), or the SQL applied by hand (it is
  idempotent).
- **Measured with Docker** (MacBook Air M2, 16 GB; a Colima VM with 6 CPUs and 8 GB running Redis
  7.4, ClickHouse 25.8.33, the ingest and the worker): `init.sql` creates the tables and the
  materialized view on a fresh volume, and all 103 service tests pass, the 10 integration tests
  included, against real Redis and ClickHouse. `mise run load` with its defaults (1,250 simulated
  servers, a gzip batch of 40 events every ~5 s, 2 minutes) stored ~29,900 batches at ~237 per
  second, ~9,500 events per second, with 0 failed requests and no 503. Two runs: p95 6.2 and
  22.5 ms, p99 11.7 and 96.9 ms (the slower one shared the VM with the dashboard polling every
  5 s). After the worker drained, ClickHouse held exactly the events accepted (1,199,720 and
  1,194,920): no duplicates, no losses.
- **End to end from Studio** (the ingest behind `mise run tunnel`, Local Secrets set): a Play Solo
  with `AnalyticsDemo` sent a batch about every 10 s, and ClickHouse stored all 36 events of its 10
  batches with the real place and user ids, none rejected, with `session_end` arriving when the
  playtest stopped.
