# Roblox platform limits

Verified on 2026-11-16 against the official docs (source in github.com/Roblox/creator-docs, updated
Oct–Nov 2026) and Roblox staff announcements on the DevForum. Roblox marks several of these as
estimates or subject to change: design with headroom, never against the exact number. `players` =
players on that server, `servers` = servers of the experience, `CCU` = players in the whole
experience. **UNCONFIRMED** = no official source; do not design around it.

Sources: `https://create.roblox.com/docs/` + the path in each section; DevForum posts as
`DF <id>` = `https://devforum.roblox.com/t/<id>`.

## HttpService

Paths: `cloud-services/http-service`, `reference/engine/classes/HttpService`, `cloud/reference/rate-limits`,
`cloud-services/secrets`.

| Limit | Value | Notes |
|---|---|---|
| External requests | 500 per minute per server | |
| Open Cloud from a game | 2,500 per minute per server | `http-service` says they do not consume the 500; `rate-limits` says they do. **Conflicting**: budget as if they do |
| Ports | 80, 443 and 1024–65535 except 1194 | |
| Timeout | `RequestAsync` field `Timeout` (seconds), no greater than the default | Default value **UNCONFIRMED** |
| Body size | **UNCONFIRMED** | Community reports an engine error "Post data too large. Limit: 1024 KB" |
| Concurrency | **UNCONFIRMED** | |
| Compression | `Compress = Enum.HttpCompression.Gzip`; HTTP/2 automatic | |
| Secrets | `GetSecret(name)`; URL and headers only, never the body; domain allowlist; 500 per experience, 1,024 characters | Studio playtests need Local Secrets |
| JSON | Since 2026-03-10 `JSONEncode` writes inf / -inf / NaN as `{"m":null,"t":"numeric","v":"inf"}` | Validate numbers before encoding (DF 4400205) |
| localhost from game scripts | **UNCONFIRMED** (docs only say plugins can) | Use a public HTTPS URL: VPS or tunnel |

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
