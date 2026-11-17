--!strict

local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")

local remote = require(replicated_storage.Shared.net.remote)
local token_bucket = require(script.Parent.token_bucket)
local trace = require(replicated_storage.Shared.util.trace)
local tuning = require(replicated_storage.Shared.config.tuning)

export type Validator = (value: unknown) -> boolean
export type Limiter = token_bucket.Limiter

local guard = {}

local limiters: { Limiter } = {}
local rejects: { [string]: { [string]: number } } = {}

local function finite(x: number): boolean
    return x == x and x ~= math.huge and x ~= -math.huge
end

local t = {}

function t.boolean(value: unknown): boolean
    return type(value) == "boolean"
end

function t.number(min: number, max: number): Validator
    return function(value)
        return type(value) == "number" and finite(value) and value >= min and value <= max
    end
end

function t.integer(min: number, max: number): Validator
    return function(value)
        return type(value) == "number" and finite(value) and value % 1 == 0 and value >= min and value <= max
    end
end

function t.string(max_bytes: number): Validator
    return function(value)
        return type(value) == "string" and #value <= max_bytes and utf8.len(value) ~= nil
    end
end

const GUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
function t.id(value: unknown): boolean
    return type(value) == "string" and string.match(value, GUID) ~= nil
end

function t.literal(...: string): Validator
    local allowed = {}

    for _, option in { ... } do
        allowed[option] = true
    end

    return function(value)
        return type(value) == "string" and allowed[value] == true
    end
end

function t.vector3(max_magnitude: number): Validator
    return function(value)
        if typeof(value) ~= "Vector3" then
            return false
        end

        local v = value :: Vector3

        return finite(v.X) and finite(v.Y) and finite(v.Z) and v.Magnitude <= max_magnitude
    end
end

function t.optional(inner: Validator): Validator
    return function(value)
        return value == nil or inner(value)
    end
end

function t.array(item: Validator, max_length: number): Validator
    return function(value)
        if type(value) ~= "table" then
            return false
        end

        local list = value :: { [unknown]: unknown }
        local n = 0

        for key in list do
            if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
                return false
            end

            n += 1
            if n > max_length then
                return false
            end
        end

        for i = 1, n do
            local entry = list[i]

            if entry == nil or not item(entry) then
                return false
            end
        end

        return true
    end
end

guard.t = table.freeze(t)

function guard.reject(name: string, reason: string, player: any)
    local by_reason = rejects[name]

    if not by_reason then
        by_reason = {}
        rejects[name] = by_reason
    end

    by_reason[reason] = (by_reason[reason] or 0) + 1
    trace("net", `{name} rejected {tostring(player)}: {reason}`)
end

function guard.limiter(rate: number?, burst: number?, clock: (() -> number)?): Limiter
    local limiter = token_bucket.new(rate or tuning.net.default_rate, burst or tuning.net.default_burst, clock)
    table.insert(limiters, limiter)

    return limiter
end

function guard.handler(name: string, limiter: Limiter?, validators: { Validator }, fn: (Player, ...any) -> any)
    local count = #validators
    return function(player: Player, ...: unknown): any
        if limiter and not limiter:take(player) then
            guard.reject(name, "rate", player)
            return remote.REJECTED
        end

        if select("#", ...) ~= count then
            guard.reject(name, "arity", player)
            return remote.REJECTED
        end

        for i, validator in validators do
            if not validator((select(i, ...))) then
                guard.reject(name, `arg{i}`, player)
                return remote.REJECTED
            end
        end

        return fn(player, ...)
    end
end

function guard.rejects(): { [string]: { [string]: number } }
    local copy = {}

    for name, by_reason in rejects do
        copy[name] = table.clone(by_reason)
    end

    return copy
end

function guard.start()
    players.PlayerRemoving:Connect(function(player)
        for _, limiter in limiters do
            limiter:forget(player)
        end
    end)
end

return guard
