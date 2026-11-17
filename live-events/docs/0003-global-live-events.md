# 0003: Global live events on a CRDT counter, sharded by known keys on MemoryStore, or on Redis

## Context

A global event (a world fishing goal, a vote for the next boss, an admin-abuse counter) needs one
number that players on every server contribute to and every server shows, a few seconds stale at
most, with no contribution lost or counted twice.

Scale is the hard part. A group of games can peak at 7.56M CCU together on a Saturday, when weekly
admin events and updates land, about 3.7x the weekday high; single Roblox games have peaked at 14.3M
and 25.8M. Spikes of 4–10x within an hour are normal. At 8 players per server, 25.8M CCU is about
3.2M servers.

The binding Roblox limits are per key and per call, not the experience quota
([platform-limits.md](platform-limits.md)): about 5,000 write and 15,000 read RU per minute on one hash map key,
`UpdateAsync` costing 2+ RU on both, MessagingService per-topic limits counting deliveries
(messages × servers), HttpService at 500 requests per minute per server. And one measurement that
changed the design: **listing a hash map walks every partition**. `ListItemsAsync` on a map with
0–7 items took 21 page calls, 5–6 seconds and about 350 RU (Studio, 2026-11-16).

## Decision

**State is a per-server cumulative counter** (G-counter; PN-counter for votes). Each server sends
its own running total, never a delta. The store keeps the newest value per server, so a retry, a
duplicate or a late older value cannot double count, and data a store loses heals when live servers
resend.

**MemoryStore backend: shards read by key, never listed.**

- A server writes its entry into shard `hash(server) % shards` with `UpdateAsync`, merging by
  maximum. About 25 servers per shard keeps each key near 625 RU/min (of ~5,000) and a shard near
  4.5 KB (of 32 KB). Shards live in one hash map per group of 256, which spreads the load over more
  partitions.
- A group leader reads its 256 shards with parallel `GetAsync` and writes a partial under a known key.
  The root leader reads every partial the same way, writes the total to version-fenced replicas and
  broadcasts it on MessagingService. The root adopts one group without a live leader per pass.
- About 8 hash-chosen candidates contest each lease, not every server; leases renew at half their
  TTL. Candidates are drawn from **live** servers: each entry carries the time of its server's last
  flush (heartbeats re-flush every 30 s), so the passes count servers seen in the last 90 s apart
  from every server that ever contributed. Counting dead servers made the pool too sparse: with 1
  live server and 18 entries in Studio, no live server was a candidate and the total stopped. While
  the total stays stale, the pool doubles every 30 s, up to the 41 contenders one lease key can take
  under its write limit, so an outdated count can delay a pass but never stop it. Every MemoryStore call goes through one gate with exponential backoff and full jitter, so a
  throttled experience is not kept throttled by its own retries.
- Pass intervals come from the RU budget of the current CCU (25% of the quota for events); readers
  fall back to their replica when broadcasts stop, with replicas and poll spacing growing with the
  server count.
- Each server shows `total + its own unsent contributions`, and a counter never goes down on screen.

**Redis backend** (`service/`): the same counter. A Lua script keeps the maximum per server
and option and moves the totals by the difference, atomically. Requests are batched every 25 ms, one
script call per event per batch, and every request waits for its batch to land, so an ack still
means stored. The response carries the totals, so one request publishes and reads. A server
publishes every event that is due, including one it only reads (no votes yet), and Roblox encodes
that empty table as `[]`, so the service takes `[]` as an empty contribution.

Measured with `mise run load` on a MacBook Air M2 (Colima VM, 6 CPUs, 8 GB): 2,000 simulated
servers publishing their total every ~2 s for 2 minutes sent 119,388 requests (975 per second) at
p50 15.6 ms, p95 27.4 ms, p99 82.4 ms, with no failed request. The stored total matched the fish
the servers had acknowledged exactly (2,323,844). All 17 service tests pass against real Redis.

End to end, a Studio playtest on the HTTP backend (`LiveEventBackend = "http"`, the service behind
`mise run tunnel`) is what found the `[]` case: every publish got a 400 while the game kept showing
its archived total plus its own fish, so players saw nothing wrong. With the fix the server's fish
reached the service within one flush and the game showed the service's total every ~5 s.

## Numbers (`tests/live_capacity.spec.luau`, 50% headroom on every limit)

| Scenario | Servers | Shards / groups | RU share | Stale typical / worst / no MessagingService |
|---|---|---|---|---|
| Typical day (85k CCU) | 4,260 | 171 / 1 | 2.9% | 6.5 s / 14 s / 27 s |
| Saturday peak of a group of games (7.56M) | 945,568 | 37,823 / 148 | 7.2% | 6.5 s / 14.4 s / 28 s |
| Single-game peak (14.3M) | 1,786,691 | 71,468 / 280 | 6.4% | 6.5 s / 14.6 s / 35 s |
| Largest single-game peak (25.8M) | 3,229,528 | 129,182 / 505 | 6.0% | 6.5 s / 14.9 s / 46 s |

Simpler designs break much earlier (same spec): every server broadcasting its count ~64 CCU, every
server contesting one leader key ~664 CCU, one counter key ~2,000 CCU, one total key read by
everyone ~14,000 CCU, one leader reading every shard ~256,000 CCU.

`tests/live_sim.spec.luau` runs 300 servers for 4 simulated minutes with ~300 crashes and
leader changes: totals match what was published exactly, p95 lag 10–13.5 s against a 23.5 s bound
that includes a leader failover, zero throttled calls.

## Alternatives

- **One slot per server, aggregated with `ListItemsAsync`:** no write contention, but every listing
  costs ~350 RU and ~5 s even on tiny maps, which throttles small games and makes passes too slow
  at scale.
- **Deltas:** a retry after a lost ack double counts unless every batch carries an id.
- **MessagingService as the data path:** best effort, no acknowledgement, deliveries grow with the
  square of the server count.
- **Sorted maps:** each one lives on a single partition (~30,000 RU/min).
- **DataStore counters:** per-key throughput and the write budget are far too low for per-second
  updates.
- **`MemoryStoreDistributedCounter`:** appeared in the API dump in August 2026, undocumented; not
  relied on.

## Consequences

- A server crash loses at most its unflushed contributions (one flush, 5–7 s). Everything published
  is counted exactly once.
- The shard count is fixed per event (a server must keep writing the same shard). Pick it from the
  planner for the expected peak; intervals and replicas adapt at run time.
- Totals survive server restarts: a new server sees the entries of the servers before it.
- Nothing in gameplay or server startup waits on the event: the MessagingService subscription runs in
  the background and contributions are counted locally first.

## Many servers at once on the real MemoryStore

`StressTest = true` also runs 12 logical servers publishing to one event for 35 s, each through its
own backoff gate, with a leader running group and root passes every 3 s. Two runs ended with the
stored total exactly equal to the fish caught (287 and 267), 12 live servers counted, and no call
throttled inside Studio's 1,000 RU/min quota. During the run the total trailed by 12 to 20 fish,
one flush interval of contributions.

## Players and durability

- **One vote per player, on any server.** The ballot is saved in the player's profile, tagged with
  the server that counted it, and only then added to that server's counter. A player can change the
  vote on that server (retract and add in the same entry); on any other server the saved ballot
  blocks a second vote. A crash can lose a vote (the save landed, the flush did not), but no
  sequence of saves, flushes and crashes counts a player twice (`live_player_state.spec`, 400 random
  steps). Moving a vote across servers would need per-player state in the shared store, and at 25.8M
  CCU that is one key per voter.
- **Goal rewards once per player.** When the global snapshot says the goal was reached, each online
  player gets the reward, and the mark that they got it is written in the same profile mutation, so
  saves can never grant it twice.
- **Archive on DataStore.** The root leader writes the totals to `LiveEvents_v1` once a minute,
  merged so the archive only grows (highest count per option, first completion, closed stays
  closed; votes keep the latest snapshot). A server that starts reads it in the background and uses
  it as the display floor, so a MemoryStore reset or the 3-day expiry never shows a lower total, and
  the result of an event outlives MemoryStore.
