--!strict

local tuning = {}

tuning.net = table.freeze({
    default_pace = table.freeze({ rate = 10, burst = 20 }),
    global_pace = table.freeze({ rate = 20, burst = 40 }),
    sync_cooldown = 1,
})

tuning.live_event = table.freeze({
    vote_pace = table.freeze({ rate = 1 / 30, burst = 3 }),
})

tuning.ui = table.freeze({
    notice_seconds = 3,
})

return table.freeze(tuning)
