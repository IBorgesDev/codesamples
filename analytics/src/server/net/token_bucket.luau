--!strict

export type Limiter = {
    take: (self: Limiter, key: any, cost: number?) -> boolean,
    forget: (self: Limiter, key: any) -> (),
}

type Bucket = { tokens: number, at: number }

local token_bucket = {}

function token_bucket.new(rate: number, burst: number, clock: (() -> number)?): Limiter
    assert(rate > 0 and burst >= 1, "[token_bucket] rate must be > 0 and burst >= 1")
    local now = clock or os.clock
    local buckets: { [any]: Bucket } = {}
    local limiter = {}

    function limiter.take(_, key: any, cost: number?): boolean
        local need = cost or 1
        local t = now()
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

    function limiter.forget(_, key: any)
        buckets[key] = nil
    end

    return limiter :: any
end

return token_bucket
