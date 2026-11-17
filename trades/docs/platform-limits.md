# Roblox platform limits

Verified on 2026-11-16 against the official docs (source in github.com/Roblox/creator-docs, updated
Oct–Nov 2026) and Roblox staff announcements on the DevForum. Roblox marks several of these as
estimates or subject to change: design with headroom, never against the exact number. `players` =
players on that server, `servers` = servers of the experience, `CCU` = players in the whole
experience. **UNCONFIRMED** = no official source; do not design around it.

Sources: `https://create.roblox.com/docs/` + the path in each section; DevForum posts as
`DF <id>` = `https://devforum.roblox.com/t/<id>`.

## MemoryStoreService

Paths: `cloud-services/memory-stores`, `…/memory-stores/hash-map`, `…/memory-stores/sorted-map`,
`…/memory-stores/best-practices`, `…/memory-stores/observability`,
`reference/engine/classes/MemoryStoreQueue`, `cloud/reference/features/storage`.

| Limit | Value | Notes |
|---|---|---|
| Request units (RU) | 1,000 + 120 × CCU per minute, per experience | Raised 20% on 2025-06-23 (DF 3774857) |
| Memory | 64 KB + 1.2 KB × users, per experience | users = peak CCU over 8 days; shrinks only after 8 days |
| Paid overage | Extended Services: $0.003 per 1M RU, $0.10 per GB-hour | `cloud-services/extended-services` |
| RU per call | Most calls 1 RU | |
| Hash map `UpdateAsync` | At least 2 RU, counts as read and write | |
| Hash map `ListItemsAsync` | partitions scanned + items returned, 1–200 items per page | One call can read a whole small map |
| Sorted map `GetRangeAsync` | items returned (empty = 1), ≤ 200 per page | |
| Queue `ReadAsync` | items returned + 1 every 2 s while waiting | `waitTimeout` defaults to -1: waits forever and keeps spending RU |
| Per hash map key | ~5,000 write RU/min and ~15,000 read RU/min | Estimates. Error `PartitionRequestsOverLimit` |
| Per partition | ~30,000 RU/min | Estimate. A sorted map or a queue lives on **one** partition |
| Per sorted map / queue | 1,000,000 items, 100 MB, 100,000 RU/min | Hash maps have no per-structure item or memory limit |
| Key / value | Key 128 characters, value 32 KB | Sort key 128 characters |
| Expiration | Up to 3,888,000 s (45 days) | |
| Atomicity | `UpdateAsync` saves only if the key did not change since it was read, else reruns the callback; `nil` cancels | Hash map keys have no ordering guarantee |
| Memory full | Writes that grow memory fail; writes that shrink or keep it flat succeed | |
| Errors | `PartitionRequestsOverLimit`, `TotalRequestsOverLimit`, `DataStructureRequestsOverLimit`, `ItemValueSizeTooLarge`, `TotalMemoryOverLimit`, `RequestThrottled`, `UpdateConflict` | |
| Open Cloud | Sorted maps and queues only, **no hash map endpoints**; 1,000,000 req/min per API key owner | Whether it draws from the game RU quota: **UNCONFIRMED** |
| Hot keys | Copy a hot key into N keys and route each server to a stable copy; split sorted maps by prefix | Best-practices page |
| Dashboard | Memory and RU by API and status, 30 days; email alerts over 70% memory, >20% failures, >10% throttled | |

Measured in a Studio playtest on 2026-11-16 (not documented by Roblox; re-measure before relying on
the exact numbers):

| Measurement | Result | Method |
|---|---|---|
| Quota in a Studio playtest | 1,000 RU/min | After 2 min idle, 1,000 parallel `GetAsync` succeeded, then `TotalRequestsOverLimit` |
| `ListItemsAsync` first page | ~21 RU per call | Same rested bucket drained by 48 first-page calls |
| Listing a whole small hash map | 21 page calls, 5–6 s, ~350 RU | Maps with 0 and 7 items: `IsFinished` stays false across ~20 empty pages, one per partition |
| Behaviour after the quota is hit | The client answers `RequestThrottled` immediately for a while | Calls that keep coming without backoff keep the experience throttled |

## MessagingService

Paths: `reference/engine/classes/MessagingService`, `cloud/guides/usage-messaging`. "Subject to change".

| Limit | Value | Notes |
|---|---|---|
| Message size | 1 KB (1,024 characters) | Topic name 1–80 characters |
| Publish | 600 + 240 × players per server, per minute | `PublishAsync` yields until the backend has it |
| Received per topic | 40 + 80 × servers per minute | |
| Received per experience | 400 + 200 × servers per minute | Across all topics |
| Subscriptions | 20 + 8 × players per server; 240 subscribe calls per minute | |
| Delivery | "Typically within 1-2 seconds", best effort, not guaranteed | Ordering and dedupe: **UNCONFIRMED**, assume none |
| Open Cloud publish | `POST /cloud/v2/universes/{id}:publishMessage`, 5,000/min per API key owner | Counts against the same limits since 2026-05-11 (DF 4600993) |

## DataStoreService

Paths: `cloud-services/data-stores/error-codes-and-limits`, `…/versioning-listing-and-caching`,
`reference/engine/classes/DataStoreService`, `reference/engine/classes/GlobalDataStore`.

| Limit | Value | Notes |
|---|---|---|
| Server, standard stores | Read, Write, Remove 60 + 40 × players per minute; List 5 + 2 × players | Defaults; `SetRateLimitForRequestType` can raise them (base ≤ 10,000, per player ≤ 200), except UpdateAsync |
| Server, ordered stores | Read 60 + 40 × players; Write and Remove 30 + 5 × players; List 5 + 2 × players | |
| Experience-wide | Read 300 + CCU × 40, Write 300 + CCU × 20, List 300 + CCU × 2, Remove 300 + CCU × 40 per minute | Since 2026-07-29, shared with Open Cloud (DF 4739240) |
| `UpdateAsync` | Spends read and write budget; callback reruns if another server wrote first, must not yield, `nil` cancels | |
| Unknown outcome | "A failed write call … does not always guarantee that the backend write did not occur" | Verify with a fresh read (`UseCache = false`) |
| Per key | Read 25 MB/min, write 4 MB/min (rolling 60 s), each request rounded up to 1 KB | `KeyThrottled`, `DatastoreThrottled`. The old same-key 6 s cooldown was removed (DF 2436230) |
| Errors | `<Type>GameServerThrottled`, `<Type>ExperienceThrottled`; queue of 30 per type, then errors 301–306 | |
| Storage | 500 MB + 1 MB × lifetime users, compressed latest versions | Over it: Robux deduction after a 2-week grace, or Extended Services |
| Names and values | Store name, key, scope 50 characters; value 4,194,304 characters; metadata 300 characters | |
| Cache | `GetAsync` caches 4 s per DataStore object; hits are free; `DataStoreGetOptions.UseCache = false` reads the backend | |
| Versions | First write per UTC hour kept; old versions expire 30 days after being overwritten | |
| Studio | Run mode has a separate, possibly lower, set of limits | |

## Servers, remotes, shutdown

Paths: `performance-optimization/identify`, `reference/engine/classes/DataModel`, `scripting/events/remote`,
`reference/engine/classes/UnreliableRemoteEvent`, `projects/teleport`.

| Limit | Value | Notes |
|---|---|---|
| Players per server | Up to 100 | Higher hard maximum **UNCONFIRMED** |
| Server memory | 6.25 GiB + 100 MiB × largest number of connected players | Keep usage under 50%; `DataModel.ServerLowMemoryWarning` since 2026-11-02 |
| `BindToClose` | 30 s total, bound functions run in parallel | |
| Client → server remotes | ~500 calls/s per client, shared by every remote of the same type | Reliable excess is delayed, unreliable excess dropped |
| Ordering | RemoteEvents arrive in order per direction, even across instances | |
| Unreliable payload | Over 1,000 bytes is dropped, both directions | Not queued when nothing listens |
| Reliable payload | **UNCONFIRMED** | |
| TeleportData | Visible to the client, unencrypted; ≤ 50 players per `TeleportAsync` | Size **UNCONFIRMED** |
| SharedTable | One DataModel only, so one server | No cross-server use |
