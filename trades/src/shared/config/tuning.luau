--!strict

local tuning = {}

tuning.net = table.freeze({
    default_pace = table.freeze({ rate = 10, burst = 20 }),
    global_pace = table.freeze({ rate = 20, burst = 40 }),
    sync_cooldown = 1,
})

tuning.trade = table.freeze({
    max_items_per_side = 12,
    max_coins_per_side = 1_000_000_000,
    invite_timeout = 30,
    result_display = 6,
    gift_pace = table.freeze({ rate = 1 / 15, burst = 3 }),
})

tuning.ui = table.freeze({
    notice_seconds = 3,
})

return table.freeze(tuning)
