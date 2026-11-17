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

tuning.trade = table.freeze({
    max_items_per_side = shared.trade.max_items_per_side,
    max_coins_per_side = shared.trade.max_coins_per_side,
    invite_timeout = shared.trade.invite_timeout,
    invite_cooldown = 3,
    max_invites = 5,
    countdown = 3,
    accept_delay = 3,
    lock_pace = table.freeze({ rate = 1 / 15, burst = 4 }),
    tick_interval = 0.25,
    close_after = 4,
    min_update_budget = 4,
    persist_timeout = 15,
    record_timeout = 120,
    missing_record_grace = 60,
    sweep_interval = 30,
    inventory_interval = 0.5,
    store_name = "Trades_v1",
})

tuning.cross = table.freeze({
    coordinator_map = "trade_coord",
    coordinator_maps = 1024,
    presence_ttl = 1200,
    presence_refresh = 600,
    session_ttl = 900,
    closed_ttl = 60,
    remote_poll_interval = 2,
    pace = table.freeze({ rate = 1 / 3, burst = 6 }),
    answer_cooldown = 10,
    lock_grace = 10,
    subscribe_retry = 10,
    backoff_base = 2,
    backoff_cap = 60,
})

tuning.gift = table.freeze({
    pace = shared.trade.gift_pace,
    min_budget = 12,
    max_outbox = 32,
    max_sends = 3,
    resend_interval = 60,
    settle_delay = 2,
    settle_interval = 60,
    inbox_store = "GiftInbox_v1",
    inbox_cap = 500,
    known_recipients = 10_000,
})

tuning.profiles = table.freeze({
    store_name = "Players_v1",
    studio_suffix = "_studio",
    message_queue = 2000,
    seed_items = 6,
    seed_coins = 500,
})

return table.freeze(tuning)
