--!strict

local replicated_storage = game:GetService("ReplicatedStorage")

local tuning = require(replicated_storage.Shared.config.tuning)

const SECONDS_PER_MINUTE = 60
const UPDATE_RU = 2

local planner = {}

local function per_minute(interval: number): number
    return SECONDS_PER_MINUTE / interval
end

local function rounds(items: number): number
    return math.max(1, math.ceil(items / tuning.platform.read_parallelism))
end

local function replica_budget(): number
    local store = tuning.platform.memory_store
    local passes = per_minute(tuning.live_event.aggregate_interval)

    return store.read_per_key * tuning.platform.safety - passes * UPDATE_RU
end

function planner.max_contenders(): number
    local store = tuning.platform.memory_store
    local passes = per_minute(tuning.live_event.aggregate_interval)

    return math.max(1, math.floor(store.write_per_key * tuning.platform.safety / (passes * UPDATE_RU)))
end

function planner.replicas(servers: number, max_replicas: number): number
    local polls = per_minute(tuning.live_event.poll_interval + tuning.live_event.flush_jitter / 2)

    return math.clamp(math.ceil(servers * polls / replica_budget()), 1, max_replicas)
end

function planner.poll_interval(servers: number, replicas: number): number
    local spread = servers * SECONDS_PER_MINUTE / (math.max(1, replicas) * replica_budget())

    return math.max(tuning.live_event.poll_interval, spread)
end

function planner.pass_cost(shards_read: number): number
    return shards_read + 1 + 1 + UPDATE_RU
end

function planner.pass_interval(ccu: number, events: number, shards_read: number?): number
    local store = tuning.platform.memory_store
    local quota = store.ru_base + store.ru_per_ccu * math.max(1, ccu)
    local budget = quota * tuning.platform.live_event_ru_share / math.max(1, events)
    local interval = SECONDS_PER_MINUTE * planner.pass_cost(shards_read or 1) / budget

    return math.clamp(interval, tuning.live_event.aggregate_interval, tuning.live_event.max_aggregate_interval)
end

function planner.root_pass_seconds(groups: number, per_group: number): number
    local calls = 1 + rounds(groups) + tuning.live_event.max_orphans * (rounds(per_group) + 1) + 1 + 1

    return calls * tuning.platform.call_seconds
end

function planner.root_interval(groups: number, per_group: number): number
    local step = tuning.live_event.aggregate_interval

    return math.max(step, math.ceil(planner.root_pass_seconds(groups, per_group) / step) * step)
end

function planner.root_lease(interval: number): number
    local config = tuning.live_event

    return math.max(config.lease_seconds, interval * config.lease_passes)
end

return planner
