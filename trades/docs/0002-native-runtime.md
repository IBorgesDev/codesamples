# 0002: Native runtime, ProfileStore as the one runtime package

## Context

This project should drop into games built on any stack. Native Roblox code is what all of them
share, and every library is one more API a reader has to learn before reading the game code.

## Decision

The project uses Roblox services and its own small modules, with one runtime package:

- **Data**: ProfileStore (server only). Session locking is easy to get subtly wrong, ProfileStore
  is the common choice in large games, and its hooks (`Save`, `OnAfterSave`, `LastSavedData`,
  `MessageAsync`) are exactly what the trade protocol needs: escrow is confirmed durable before a
  vote, gifts go through its message queue.
- **Networking**: native remotes behind `src/shared/net` (decision 0001).
- **UI**: Instances built in code, updated from state snapshots, instead of Vide.
- **Debug numbers**: attributes on `ServerStorage.DevStats` (`src/server/dev/stats.luau`) instead of a
  Lori panel.

TestEZ stays as a dev package: it only runs the specs in Studio, lives in `ServerStorage` and never
reaches a client.

## Alternatives

- **Own session lock on `DataStoreService`**: shows the mechanism, but it is a few hundred lines of
  the riskiest code in the game for no gain over a library built for it.
- **Vide / React-lua**: worth it for large, nested UIs. The trade window is one screen.
- **Trove, Lori**: small and good, but each saves a few lines at the cost of one more API.

## Consequences

- UI and debug tooling are code to own.
- Two package folders in the place: `ServerScriptService.ServerPackages` (ProfileStore) and
  `ServerStorage.DevPackages` (TestEZ). Nothing in `ReplicatedStorage.Packages`.
- Adding a runtime package needs a new decision here.
