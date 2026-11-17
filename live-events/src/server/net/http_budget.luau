--!strict

local replicated_storage = game:GetService("ReplicatedStorage")

local token_bucket = require(replicated_storage.Shared.net.token_bucket)
local tuning = require(replicated_storage.Shared.config.tuning)

const SECONDS_PER_MINUTE = 60

local limiters: { [string]: token_bucket.Limiter } = {}

local http_budget = {}

function http_budget.take(consumer: string, clock: (() -> number)?): boolean
    local limiter = limiters[consumer]
    if not limiter then
        local share = tuning.http.shares[consumer]
        assert(share, `[http_budget] no share for {consumer}`)
        limiter = token_bucket.new(share / SECONDS_PER_MINUTE, share / SECONDS_PER_MINUTE * 10, clock)
        limiters[consumer] = limiter
    end

    return limiter:take(consumer)
end

function http_budget.reserved(): number
    local total = 0
    for _, share in tuning.http.shares do
        total += share :: number
    end

    return total
end

return http_budget
