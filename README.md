# Roblox backend systems

Four independent projects. Each folder is a complete project with its own code, tests, docs and
README; nothing is shared between them, and each Roblox project syncs with Rojo on its own.

| Project | What it does |
|---|---|
| [trades](trades/) | Two-way trades that never lose or duplicate an item, even when a server crashes mid-trade. Also across servers and gifts to offline players |
| [live-events](live-events/) | A global goal or vote that every server adds to and shows within seconds |
| [analytics](analytics/) | Game events into ClickHouse, each batch stored exactly once |
| [dashboard](dashboard/) | A live web dashboard over the analytics and the live events |

To open one of the Roblox projects, go into its folder and run:

```bash
mise install
mise run install
mise run serve
```

Then Connect in the Studio Rojo plugin. Every Studio playtest runs that project's specs first.
