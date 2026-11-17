--!strict

const OFFSET = 2166136261
const MODULO = 4294967296

local hash = {}

function hash.fnv1a32(text: string): number
    local value = OFFSET
    for index = 1, #text do
        value = bit32.bxor(value, string.byte(text, index))
        value = (bit32.lshift(value, 24) + value * 403) % MODULO
    end

    return value
end

function hash.bucket(text: string, buckets: number): number
    return hash.fnv1a32(text) % buckets + 1
end

return hash
