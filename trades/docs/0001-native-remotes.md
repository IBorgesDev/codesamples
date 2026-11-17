# 0001: Native remotes, no networking library

## Context

The game needs client intents, server pushes, client requests with replies and per-player state
snapshots. Libraries like Blink (IDL + buffer codegen) or defnet cover this, but they add a build
step or a runtime codec that a reviewer has to learn before reading the game code.

## Decision

Use native `RemoteEvent` / `UnreliableRemoteEvent` behind a ~200-line wrapper
(`src/shared/net/remote.luau`) with four shapes: `to_server`, `to_client`, `request`, `state`.
Every remote is declared once in `src/shared/net/init.luau`. No `RemoteFunction`.

- Server handlers receive `...unknown`, so the type checker forces each argument through
  `src/server/net/guard.luau` (rate limit, exact arity, one validator per argument).
- `request` is two RemoteEvents plus a request id and a client-side timeout. `InvokeClient` can park a
  server thread forever, and `InvokeServer` has no timeout.
- `state` stamps snapshots with a server-wide sequence number and supports a resync request, so a
  client never applies an older snapshot and never misses the first one.

## Alternatives

- **Blink**: smallest payloads (buffers) and generated types. Worth it when bandwidth is the
  bottleneck (many entities per frame). Trades send a few small messages per player
  per second, so the gain doesn't pay for the extra toolchain here.
- **defnet** (used in another project): state diffing per player on Heartbeat, but its codec rejects
  non-ASCII strings and shared tables need manual flushing.

## Consequences

- Payloads are plain Luau tables, so bandwidth is higher than with a buffer codec. Keep snapshots to
  ids and numbers.
- Switching a hot path to Blink later only touches its declaration and call sites.
