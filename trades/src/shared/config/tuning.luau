--!strict

local tuning = {}

tuning.net = table.freeze({
    request_timeout = 10,
    sync_cooldown = 1,
    default_pace = table.freeze({ rate = 10, burst = 20 }),
    global_pace = table.freeze({ rate = 20, burst = 40 }),
    strike_limit = 5,
    strike_window = 60,
    flood_limit = 300,
})

tuning.trade = table.freeze({
    max_items_per_side = 12,
    max_coins_per_side = 1_000_000_000,
    countdown = 3,
    accept_delay = 3,
    max_invites = 5,
    closed_ttl = 60,
    cross_pace = table.freeze({ rate = 1 / 3, burst = 6 }),
    cross_answer_cooldown = 10,
    gift_pace = table.freeze({ rate = 1 / 15, burst = 3 }),
    gift_min_budget = 12,
    persist_timeout = 15,
    record_timeout = 120,
    missing_record_grace = 60,
    sweep_interval = 30,
    store_name = "Trades_v1",
    invite_timeout = 30,
    invite_cooldown = 3,
    tick_interval = 0.25,
    close_after = 4,
    min_update_budget = 4,
    coordinator_map = "trade_coord",
    presence_ttl = 1200,
    presence_refresh = 600,
    session_ttl = 900,
    remote_poll_interval = 2,
    max_outbox = 32,
    inventory_interval = 0.5,
    result_display = 6,
    gift_resend_interval = 60,
    inbox_store = "GiftInbox_v1",
    inbox_cap = 500,
    inbox_settle_delay = 2,
    coordinator_maps = 1024,
    lock_grace = 10,
    subscribe_retry = 10,
    backoff_base = 2,
    backoff_cap = 60,
})

tuning.profiles = table.freeze({
    store_name = "Players_v1",
    studio_suffix = "_studio",
    message_queue = 2000,
    seed_items = 6,
    seed_coins = 500,
})

tuning.ui = table.freeze({
    notice_seconds = 3,
})

tuning.platform = table.freeze({
    memory_store = table.freeze({
        ru_base = 1_000,
        ru_per_ccu = 120,
        read_per_key = 15_000,
        partitions_per_map = 20,
        per_partition = 30_000,
        memory_base = 64 * 1024,
        memory_per_ccu = 1.2 * 1024,
    }),
    messaging = table.freeze({
        per_game_base = 400,
        per_game_per_server = 200,
    }),
    safety = 0.5,
    trade_ru_share = 0.25,
})

return table.freeze(tuning)
