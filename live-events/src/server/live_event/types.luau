--!strict

local counter = require(script.Parent.counter)

export type Tally = counter.Tally
export type Entry = counter.Entry
export type Shard = counter.Shard

export type State = "live" | "completed" | "closed"

export type Goal = {
    option: string,
    target: number,
}

export type Kind = "counter" | "vote"

export type Spec = {
    id: string,
    kind: Kind,
    options: { string },
    goal: Goal?,
    ends_at: number?,
    shards: number,
}

export type Snapshot = {
    state: State,
    version: number,
    totals: Tally,
    completed_at: number?,
    ends_at: number?,
    servers: number,
    live: number?,
    replicas: number,
    at: number,
}

export type Partial = {
    totals: Tally,
    servers: number,
    live: number?,
    at: number,
}

export type Layout = {
    shards_per_group: number,
    max_replicas: number,
    close_grace: number,
    candidates: number,
    live_window: number?,
}

export type Backend = {
    publish: (server_id: string, entries: { [string]: Entry }, sync: boolean) -> (boolean, { [string]: Snapshot }?),
    read: (event_id: string) -> (boolean, Snapshot?),
}

export type ShardStore = {
    update: (event_id: string, group: number, shard: number, transform: counter.Transform) -> boolean,
    read_many: (event_id: string, group: number, shards: { number }) -> (boolean, { [number]: Shard }?),
}

export type PartialStore = {
    write: (event_id: string, group: number, partial: Partial) -> boolean,
    read_many: (event_id: string, groups: { number }) -> (boolean, { [number]: Partial }?),
}

export type TotalStore = {
    read: (event_id: string, replica: number) -> (boolean, Snapshot?),
    write: (event_id: string, replica: number, snapshot: Snapshot) -> boolean,
    write_all: (event_id: string, count: number, snapshot: Snapshot) -> number,
}

export type Lease = {
    acquire: (event_id: string, role: string, server_id: string, ttl: number) -> boolean,
}

export type Broadcast = {
    send: (event_id: string, snapshot: Snapshot) -> boolean,
}

export type Ports = {
    shards: ShardStore,
    partials: PartialStore,
    totals: TotalStore,
    lease: Lease,
    broadcast: Broadcast,
}

export type Ballot = {
    option: string,
    plus: counter.Tally?,
    minus: counter.Tally?,
    server: string?,
    published: boolean?,
}

export type PlayerData = {
    coins: number,
    live_votes: { [string]: Ballot },
    live_rewards: { [string]: number },
}

export type Account = {
    user_id: number,
    data: PlayerData,
    active: () -> boolean,
    persist: (durable: (saved: PlayerData) -> boolean) -> boolean,
}

return {}
