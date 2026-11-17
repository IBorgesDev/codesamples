--!strict

export type Limiter = {
    take: (self: Limiter, key: any, cost: number?) -> boolean,
}

type Bucket = { tokens: number, at: number }

local token_bucket = {}

function token_bucket.new(rate: number, burst: number): Limiter
    assert(rate > 0 and burst >= 1, "[token_bucket] rate must be > 0 and burst >= 1")
    local buckets: { [any]: Bucket } = {}
    local limiter = {}

    function limiter.take(_, key: any, cost: number?): boolean
        local need = cost or 1
        local t = os.clock()
        local bucket = buckets[key]

        if not bucket then
            bucket = { tokens = burst, at = t }
            buckets[key] = bucket
        end

        bucket.tokens = math.min(burst, bucket.tokens + (t - bucket.at) * rate)
        bucket.at = t
        if bucket.tokens < need then
            return false
        end

        bucket.tokens -= need

        return true
    end

    return limiter :: any
end

return token_bucket
