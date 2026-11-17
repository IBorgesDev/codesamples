# Live events

Code for global live events in a Roblox game: a world goal or a vote that players on every server
add to and see within seconds.

It solves counting across millions of servers: no contribution or vote is lost or counted twice,
even through crashes and retries, and it stays inside Roblox's MemoryStore limits up to 76M players
online. `service/` is an optional Redis backend for games that prefer their own.

## Run

```bash
mise install
mise run install
mise run serve
```

Connect the Rojo plugin in Studio (port 34875) and enable Studio Access to API Services. Every
playtest runs the tests first. `mise run up` starts the Redis backend with Docker.
