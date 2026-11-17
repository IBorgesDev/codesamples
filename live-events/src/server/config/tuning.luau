--!strict

local replicated_storage = game:GetService("ReplicatedStorage")

local shared = require(replicated_storage.Shared.config.tuning)

local tuning = {}

tuning.net = table.freeze({
    default_pace = shared.net.default_pace,
    global_pace = shared.net.global_pace,
    strike_limit = 5,
    strike_window = 60,
    flood_limit = 300,
})

tuning.profiles = table.freeze({
    store_name = "Players_v1",
    studio_suffix = "_studio",
    persist_timeout = 15,
})

tuning.live_event = table.freeze({
    backend = "memory_store",
    url_secret = "events_url",
    token_secret = "events_token",
    archive_store = "LiveEvents_v1",
    archive_interval = 60,
    reward_interval = 5,
    flush_interval = 5,
    flush_jitter = 2,
    heartbeat = 30,
    live_window = 90,
    widen_every = 30,
    aggregate_interval = 2,
    max_aggregate_interval = 60,
    group_heartbeat = 10,
    total_heartbeat = 10,
    orphan_after = 30,
    max_orphans = 1,
    stale_after = 8,
    poll_interval = 6,
    lease_seconds = 10,
    lease_passes = 2.5,
    vote_pace = shared.live_event.vote_pace,
    vote_min_budget = 4,
    backoff_base = 2,
    backoff_cap = 60,
    max_replicas = 1024,
    shards_per_group = 256,
    servers_per_shard = 25,
    shard_fill = 0.9,
    root_candidates = 8,
    group_candidates = 3,
    close_grace = 60,
    expiration = 3 * 24 * 60 * 60,
    push_interval = 0.5,
    shutdown_flush_timeout = 5,
    subscribe_retry = 10,
    http_flush_interval = 2,
    breaker_failures = 5,
    breaker_cooldown = 15,
})

tuning.http = table.freeze({
    burst_seconds = 10,
    shares = table.freeze({
        live_event = 60,
    }),
})

tuning.platform = table.freeze({
    memory_store = table.freeze({
        ru_base = 1_000,
        ru_per_ccu = 120,
        write_per_key = 5_000,
        read_per_key = 15_000,
        value_bytes = 32 * 1024,
    }),
    safety = 0.5,
    live_event_ru_share = 0.25,
    call_seconds = 0.05,
    read_parallelism = 32,
})

return table.freeze(tuning)
