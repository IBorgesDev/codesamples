--!strict

local tuning = {}

tuning.analytics = table.freeze({
    flush_interval = 10,
    check_interval = 1,
    buffer_capacity = 5_000,
    backoff_base = 2,
    backoff_cap = 60,
    breaker_failures = 5,
    breaker_cooldown = 30,
    shutdown_flush_timeout = 3,
    max_retry_seconds = 50 * 60,
    url_secret = "analytics_url",
    token_secret = "analytics_token",
})

tuning.http = table.freeze({
    shares = table.freeze({
        analytics = 240,
    }),
})

return table.freeze(tuning)
