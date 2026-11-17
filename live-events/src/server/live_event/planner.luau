--!strict

local replicated_storage = game:GetService("ReplicatedStorage")

local tuning = require(replicated_storage.Shared.config.tuning)

const SECONDS_PER_MINUTE = 60
const ENTRY_BASE_BYTES = 67
const VOTER_BASE_BYTES = 40
const OPTION_BYTES = 24
const PARTIAL_BASE_BYTES = 64
const SNAPSHOT_BASE_BYTES = 160
const UPDATE_RU = 2
const EPSILON = 1e-6

export type Scenario = {
    name: string,
    ccu: number,
    players_per_server: number,
    churn: number,
    events: number,
    options: number,
    voter_share: number?,
}

export type Plan = {
    scenario: Scenario,
    servers: number,
    lifetime_servers: number,
    shards: number,
    groups: number,
    replicas: number,
    ru_steady: number,
    ru_outage: number,
    ru_quota: number,
    ru_share: number,
    breakdown: { [string]: number },
    shard_write_ru: number,
    shard_read_ru: number,
    hottest_write_key: number,
    hottest_read_key: number,
    shard_bytes: number,
    busiest_map_ru: number,
    memory_bytes: number,
    memory_quota: number,
    deliveries_per_topic: number,
    delivery_limit_topic: number,
    deliveries_per_game: number,
    delivery_limit_game: number,
    group_pass_seconds: number,
    root_pass_seconds: number,
    root_interval: number,
    root_lease: number,
    staleness_typical: number,
    staleness_worst: number,
    staleness_failover: number,
    staleness_outage: number,
    http_per_server_minute: number,
    http_service_rps: number,
}

export type Breakpoint = {
    design: string,
    max_servers: number,
    max_ccu: number,
}

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

function planner.shards(servers: number, lifetime: number?, voters: number?, options: number?): number
    local config = tuning.live_event
    local store = tuning.platform.memory_store
    local option_bytes = OPTION_BYTES * (options or 1)
    local bytes = (lifetime or servers) * (ENTRY_BASE_BYTES + option_bytes)
        + (voters or 0) * (VOTER_BASE_BYTES + 2 * option_bytes)
    local by_writes = math.ceil(servers / config.servers_per_shard)
    local by_bytes = math.ceil(bytes / (store.value_bytes * tuning.platform.safety * config.shard_fill))

    return math.max(1, by_writes, by_bytes)
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

function planner.listing_ru(): number
    local store = tuning.platform.memory_store

    return store.list_pages * store.page_ru
end

function planner.plan(scenario: Scenario, overrides: { shards: number? }?): Plan
    local config = tuning.live_event
    local limits = tuning.platform
    local store = limits.memory_store
    local messaging = limits.messaging
    local chosen: { shards: number? } = overrides or {}

    local servers = math.ceil(scenario.ccu / scenario.players_per_server)
    local lifetime = math.ceil(servers * scenario.churn)
    local voters = scenario.ccu * (scenario.voter_share or 0)
    local votes_per_minute = voters / config.vote_minutes
    local flushes = per_minute(config.flush_interval + config.flush_jitter / 2)
    local passes = per_minute(config.aggregate_interval)

    local shards = chosen.shards or planner.shards(servers, lifetime, voters, scenario.options)
    local groups = math.max(1, math.ceil(shards / config.shards_per_group))
    local per_group = math.min(shards, config.shards_per_group)
    local replicas = planner.replicas(servers, config.max_replicas)
    local poll_every = planner.poll_interval(servers, replicas)

    local updates_per_shard = (servers * flushes * config.conflict_overhead + votes_per_minute) / shards
    local shard_write_ru = updates_per_shard * UPDATE_RU
    local shard_read_ru = shard_write_ru + passes
    local option_bytes = OPTION_BYTES * scenario.options
    local shard_bytes = lifetime / shards * (ENTRY_BASE_BYTES + option_bytes)
        + voters / shards * (VOTER_BASE_BYTES + 2 * option_bytes)

    local breakdown: { [string]: number } = {
        shard_updates = servers * flushes * config.conflict_overhead * UPDATE_RU,
        voter_updates = votes_per_minute * UPDATE_RU,
        group_reads = shards * passes,
        group_leases = groups * config.group_candidates * passes * UPDATE_RU,
        partial_writes = groups * passes,
        root_reads = groups * passes,
        root_lease = config.root_candidates * passes * UPDATE_RU,
        replica_writes = replicas * passes * UPDATE_RU,
    }

    local steady = 0
    for _, value in breakdown do
        steady += value
    end

    local outage_polls = servers * per_minute(poll_every)
    local quota = store.ru_base + store.ru_per_ccu * scenario.ccu
    local memory = scenario.events
            * (lifetime * (ENTRY_BASE_BYTES + option_bytes) + groups * (PARTIAL_BASE_BYTES + option_bytes) + replicas * (SNAPSHOT_BASE_BYTES + option_bytes))
        + voters * (VOTER_BASE_BYTES + 2 * option_bytes)

    local group_calls = 1 + rounds(per_group) + 1
    local root_seconds = planner.root_pass_seconds(groups, per_group)
    local root_interval = planner.root_interval(groups, per_group)
    local root_lease = planner.root_lease(root_interval)

    local flush_window = config.flush_interval + config.flush_jitter
    local pipeline = config.aggregate_interval + root_interval + group_calls * limits.call_seconds + root_seconds
    local http_per_minute = per_minute(config.http_flush_interval + config.flush_jitter / 2)

    return {
        scenario = scenario,
        servers = servers,
        lifetime_servers = lifetime,
        shards = shards,
        groups = groups,
        replicas = replicas,
        ru_steady = steady * scenario.events,
        ru_outage = (steady + outage_polls) * scenario.events,
        ru_quota = quota,
        ru_share = (steady + outage_polls) * scenario.events / quota,
        breakdown = breakdown,
        shard_write_ru = shard_write_ru,
        shard_read_ru = shard_read_ru,
        hottest_write_key = math.max(
            shard_write_ru,
            config.group_candidates * passes * UPDATE_RU,
            config.root_candidates * passes * UPDATE_RU,
            passes * UPDATE_RU
        ),
        hottest_read_key = math.max(shard_read_ru, passes * UPDATE_RU + outage_polls / replicas),
        shard_bytes = shard_bytes,
        busiest_map_ru = per_group * (shard_write_ru + passes),
        memory_bytes = memory,
        memory_quota = store.memory_base + store.memory_per_ccu * scenario.ccu,
        deliveries_per_topic = passes * servers,
        delivery_limit_topic = messaging.per_topic_base + messaging.per_topic_per_server * servers,
        deliveries_per_game = scenario.events * passes * servers,
        delivery_limit_game = messaging.per_game_base + messaging.per_game_per_server * servers,
        group_pass_seconds = group_calls * limits.call_seconds,
        root_pass_seconds = root_seconds,
        root_interval = root_interval,
        root_lease = root_lease,
        staleness_typical = flush_window / 2
            + (config.aggregate_interval + root_interval) / 2
            + messaging.delivery_seconds / 2,
        staleness_worst = flush_window + pipeline + messaging.delivery_seconds,
        staleness_failover = flush_window + pipeline + messaging.delivery_seconds + root_lease,
        staleness_outage = flush_window + pipeline + config.stale_after + poll_every,
        http_per_server_minute = http_per_minute,
        http_service_rps = servers * http_per_minute / SECONDS_PER_MINUTE,
    }
end

function planner.check(plan: Plan): { string }
    local limits = tuning.platform
    local store = limits.memory_store
    local safety = limits.safety
    local problems = {}

    local function require_that(ok: boolean, message: string)
        if not ok then
            table.insert(problems, message)
        end
    end

    require_that(plan.ru_share <= limits.live_event_ru_share, `RU share {plan.ru_share}`)
    require_that(
        plan.hottest_write_key <= store.write_per_key * safety + EPSILON,
        `hottest write key {plan.hottest_write_key} RU/min`
    )
    require_that(
        plan.hottest_read_key <= store.read_per_key * safety + EPSILON,
        `hottest read key {plan.hottest_read_key} RU/min`
    )
    require_that(plan.shard_bytes <= store.value_bytes * safety, `shard of {plan.shard_bytes} bytes`)
    require_that(
        plan.busiest_map_ru <= store.partitions_per_map * store.per_partition * safety,
        `busiest hash map {plan.busiest_map_ru} RU/min`
    )
    require_that(plan.memory_bytes <= plan.memory_quota * limits.live_event_ru_share, `memory {plan.memory_bytes}`)
    require_that(plan.deliveries_per_topic <= plan.delivery_limit_topic * safety, "deliveries per topic")
    require_that(plan.deliveries_per_game <= plan.delivery_limit_game * safety, "deliveries per experience")
    require_that(plan.group_pass_seconds <= tuning.live_event.aggregate_interval * safety, "group pass too slow")
    require_that(plan.root_pass_seconds <= plan.root_lease * safety, "root pass outlives half its lease")
    require_that(plan.staleness_worst <= tuning.live_event.max_staleness, `worst staleness {plan.staleness_worst} s`)
    require_that(plan.http_per_server_minute <= tuning.http.shares.live_event, "HTTP share per server")

    return problems
end

function planner.breakpoints(scenario: Scenario): { Breakpoint }
    local config = tuning.live_event
    local store = tuning.platform.memory_store
    local messaging = tuning.platform.messaging
    local flushes = per_minute(config.flush_interval + config.flush_jitter / 2)
    local passes = per_minute(config.aggregate_interval)
    local polls = per_minute(config.poll_interval + config.flush_jitter / 2)
    local reads_per_pass = config.aggregate_interval / tuning.platform.call_seconds * tuning.platform.read_parallelism

    local designs: { { any } } = {
        { "every server updates one counter key", store.write_per_key / (flushes * UPDATE_RU) },
        { "every server reads one total key", store.read_per_key / polls },
        { "every server contests one leader key", store.write_per_key / (passes * UPDATE_RU) },
        { "one leader reads every shard", reads_per_pass * config.servers_per_shard },
        { "every server broadcasts its count", messaging.per_topic_per_server / flushes },
    }

    local out = {}
    for _, design in designs do
        local max_servers = math.floor(design[2])
        table.insert(out, {
            design = design[1],
            max_servers = max_servers,
            max_ccu = max_servers * scenario.players_per_server,
        })
    end

    return out
end

return planner
