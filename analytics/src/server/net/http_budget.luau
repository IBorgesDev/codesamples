--!strict

local token_bucket = require(script.Parent.token_bucket)
local tuning = require(script.Parent.Parent.config.tuning)

const CONFIG = tuning.http
const SECONDS_PER_MINUTE = 60

local limiters: { [string]: token_bucket.Limiter } = {}

local http_budget = {}

function http_budget.take(consumer: string): boolean
    local limiter = limiters[consumer]
    if not limiter then
        local share = CONFIG.shares[consumer]
        assert(share, `[http_budget] no share for {consumer}`)

        local per_second = share / SECONDS_PER_MINUTE
        limiter = token_bucket.new(per_second, per_second * CONFIG.burst_seconds)
        limiters[consumer] = limiter
    end

    return limiter:take(consumer)
end

return http_budget
