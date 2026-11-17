--!strict

local tuning = {}

tuning.net = table.freeze({
    request_timeout = 10,
    sync_cooldown = 1,
    default_rate = 10,
    default_burst = 20,
})

tuning.profiles = table.freeze({
    store_name = "Players_v1",
    studio_suffix = "_studio",
    persist_timeout = 15,
})

tuning.live_event = table.freeze({
    backend = "memory_store",
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
    max_staleness = 30,
    backoff_base = 2,
    backoff_cap = 60,
    max_replicas = 1024,
    servers_per_shard = 25,
    shards_per_group = 256,
    conflict_overhead = 1.25,
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
    per_minute = 500,
    shares = table.freeze({
        live_event = 60,
    }),
})

tuning.ui = table.freeze({
    notice_seconds = 3,
})

tuning.platform = table.freeze({
    memory_store = table.freeze({
        ru_base = 1_000,
        ru_per_ccu = 120,
        write_per_key = 5_000,
        read_per_key = 15_000,
        value_bytes = 32 * 1024,
        list_pages = 21,
        page_ru = 17,
        partitions_per_map = 20,
        per_partition = 30_000,
        memory_base = 64 * 1024,
        memory_per_ccu = 1.2 * 1024,
    }),
    messaging = table.freeze({
        per_topic_base = 40,
        per_topic_per_server = 80,
        per_game_base = 400,
        per_game_per_server = 200,
        message_bytes = 1024,
        delivery_seconds = 2,
    }),
    http = table.freeze({
        per_server_minute = 500,
    }),
    safety = 0.5,
    live_event_ru_share = 0.25,
    call_seconds = 0.05,
    read_parallelism = 32,
})

return table.freeze(tuning)
