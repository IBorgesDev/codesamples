--!strict

local counter = require(script.Parent.counter)
local hash = require(script.Parent.Parent.util.hash)
local planner = require(script.Parent.planner)
local types = require(script.Parent.types)

type Layout = types.Layout
type Partial = types.Partial
type Ports = types.Ports
type Snapshot = types.Snapshot
type Spec = types.Spec
type Tally = types.Tally

export type Root = {
    previous: Snapshot?,
    cursor: number,
}

export type Group = {
    previous: Partial?,
}

const ROOT_ROLE = "root"

local aggregator = {}

function aggregator.shard_of(server_id: string, shards: number): number
    return hash.bucket(server_id, shards)
end

function aggregator.groups(spec: Spec, layout: Layout): number
    return math.max(1, math.ceil(spec.shards / layout.shards_per_group))
end

function aggregator.group_of(shard: number, layout: Layout): number
    return (shard - 1) // layout.shards_per_group + 1
end

function aggregator.shards_in(group: number, spec: Spec, layout: Layout): { number }
    local first = (group - 1) * layout.shards_per_group + 1
    local last = math.min(spec.shards, group * layout.shards_per_group)
    local out = {}
    for shard = first, last do
        table.insert(out, shard)
    end

    return out
end

function aggregator.replica_of(server_id: string, replicas: number): number
    return hash.bucket(`replica:{server_id}`, replicas)
end

function aggregator.group_role(group: number): string
    return `group:{group}`
end

function aggregator.root_role(): string
    return ROOT_ROLE
end

function aggregator.population(snapshot: Snapshot?): number
    if snapshot == nil then
        return 0
    end

    return snapshot.live or snapshot.servers
end

function aggregator.widened(wanted: number, stale_for: number, step: number, cap: number): number
    local doublings = math.max(0, math.floor(stale_for / step))

    return math.min(math.max(wanted, cap), wanted * 2 ^ doublings)
end

function aggregator.candidate(server_id: string, role: string, population: number, wanted: number): boolean
    local modulo = math.max(1, math.floor(population / wanted))

    return hash.bucket(`{role}:{server_id}`, modulo) == 1
end

function aggregator.publish(ports: Ports, spec: Spec, layout: Layout, server_id: string, entry: types.Entry): boolean
    local shard = aggregator.shard_of(server_id, spec.shards)

    return ports.shards.update(spec.id, aggregator.group_of(shard, layout), shard, counter.publish(server_id, entry))
end

local function same(a: Tally, b: Tally): boolean
    for option, value in a do
        if b[option] ~= value then
            return false
        end
    end

    for option in b do
        if a[option] == nil then
            return false
        end
    end

    return true
end

function aggregator.group_pass(
    ports: Ports,
    spec: Spec,
    layout: Layout,
    group: number,
    state: Group,
    now: number,
    heartbeat: number
): (Partial?, string?)
    local ok, shards = ports.shards.read_many(spec.id, group, aggregator.shards_in(group, spec, layout))
    if not ok then
        return nil, "shards_read_failed"
    end

    local since = if layout.live_window then now - layout.live_window else nil
    local totals, servers, live = counter.totals(shards or {}, since)
    local previous = state.previous
    if
        previous
        and previous.servers == servers
        and previous.live == live
        and same(previous.totals, totals)
        and now - previous.at < heartbeat
    then
        return previous, nil
    end

    local partial: Partial = { totals = totals, servers = servers, live = live, at = now }
    if not ports.partials.write(spec.id, group, partial) then
        return nil, "partial_write_failed"
    end

    state.previous = partial

    return partial, nil
end

function aggregator.next(
    spec: Spec,
    previous: Snapshot?,
    totals: Tally,
    servers: number,
    replicas: number,
    now: number,
    close_grace: number
): Snapshot
    if previous and previous.state == "closed" then
        return previous
    end

    local state: types.State = if previous then previous.state else "live"
    local completed_at = if previous then previous.completed_at else nil
    local ends_at = spec.ends_at

    if ends_at and now >= ends_at + close_grace then
        state = "closed"
    elseif state == "live" and spec.goal and (totals[spec.goal.option] or 0) >= spec.goal.target then
        state = "completed"
        completed_at = now
    end

    local changed = previous == nil
        or state ~= previous.state
        or servers ~= previous.servers
        or replicas ~= previous.replicas
        or not same(totals, previous.totals)

    return {
        state = state,
        version = (if previous then previous.version else 0) + (if changed then 1 else 0),
        totals = totals,
        completed_at = completed_at,
        ends_at = ends_at,
        servers = servers,
        replicas = replicas,
        at = now,
    }
end

function aggregator.root_pass(
    ports: Ports,
    spec: Spec,
    layout: Layout,
    root: Root,
    now: number,
    heartbeat: number,
    orphan_after: number,
    max_orphans: number
): (Snapshot?, string?)
    if root.previous == nil then
        local ok, current = ports.totals.read(spec.id, 1)
        if not ok then
            return nil, "total_read_failed"
        end

        root.previous = current
    end

    local groups = aggregator.groups(spec, layout)
    local wanted = {}
    for group = 1, groups do
        table.insert(wanted, group)
    end

    local ok, partials = ports.partials.read_many(spec.id, wanted)
    if not ok then
        return nil, "partials_read_failed"
    end

    local known: { [number]: Partial } = partials or {}
    local adopted = 0
    local start = root.cursor
    for step = 1, groups do
        if adopted >= max_orphans then
            break
        end

        local group = (start + step - 1) % groups + 1
        local partial = known[group]
        if partial == nil or now - partial.at >= orphan_after then
            adopted += 1
            root.cursor = group
            local fresh = aggregator.group_pass(ports, spec, layout, group, { previous = nil }, now, 0)
            if fresh then
                known[group] = fresh
            end
        end
    end

    local totals: Tally = {}
    local servers = 0
    local live = 0
    for _, partial in known do
        counter.sum(totals, partial.totals)
        servers += partial.servers
        live += partial.live or partial.servers
    end

    local previous = root.previous
    local replicas = planner.replicas(live, layout.max_replicas)
    local snapshot = aggregator.next(spec, previous, totals, servers, replicas, now, layout.close_grace)
    snapshot.live = live
    if previous and snapshot.version == previous.version and now - previous.at < heartbeat then
        return previous, nil
    end

    ports.totals.write_all(spec.id, snapshot.replicas, snapshot)
    ports.broadcast.send(spec.id, snapshot)
    root.previous = snapshot

    return snapshot, nil
end

function aggregator.newer(current: Snapshot?, incoming: Snapshot?): boolean
    if incoming == nil then
        return false
    end

    if current == nil then
        return true
    end

    return incoming.version > current.version or (incoming.version == current.version and incoming.at > current.at)
end

return aggregator
