--!strict

local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")

local remote = require(replicated_storage.Shared.net.remote)
local stat = require(script.Parent.Parent.dev.stats)
local token_bucket = require(replicated_storage.Shared.net.token_bucket)
local trace = require(replicated_storage.Shared.util.trace)
local tuning = require(replicated_storage.Shared.config.tuning)

export type Validator = (value: unknown) -> boolean
export type Limiter = token_bucket.Limiter
export type Category = "malformed" | "flood"
export type Violation = (player: Player, name: string, category: Category, count: number) -> ()

const CONFIG = tuning.net
const KICK_MESSAGE = "Disconnected: invalid requests"

local guard = {}

local limiters: { Limiter } = {}
local rejects: { [string]: { [string]: number } } = {}
local counts: { [any]: { malformed: number, flood: number, since: number } } = {}
local listeners: { [{}]: Violation } = {}
local warned: { [string]: boolean } = {}
local global = token_bucket.new(CONFIG.global_pace.rate, CONFIG.global_pace.burst)
table.insert(limiters, global)

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
    stat(`net.{name}.{reason}`, by_reason[reason])
    trace("net", `{name} rejected {tostring(player)}: {reason}`)
end

function guard.on_violation(fn: Violation): () -> ()
    local key = {}
    listeners[key] = fn

    return function()
        listeners[key] = nil
    end
end

local function violation(name: string, category: Category, player: any)
    local now = os.clock()
    local entry = counts[player]
    if entry == nil or now - entry.since > CONFIG.strike_window then
        entry = { malformed = 0, flood = 0, since = now }
        counts[player] = entry
    end

    entry[category] += 1
    stat(`net.violations.{category}`, entry[category])
    for _, fn in listeners do
        fn(player, name, category, entry[category])
    end
end

function guard.limiter(pace: remote.Pace?, clock: (() -> number)?): Limiter
    local chosen = pace or CONFIG.default_pace
    local limiter = token_bucket.new(chosen.rate, chosen.burst, clock)
    table.insert(limiters, limiter)

    return limiter
end

function guard.handler(name: string, limiter: Limiter?, validators: { Validator }, fn: (Player, ...any) -> any)
    local count = #validators
    return function(player: Player, ...: unknown): any
        if not global:take(player) or (limiter and not limiter:take(player)) then
            guard.reject(name, "rate", player)
            violation(name, "flood", player)
            return remote.REJECTED
        end

        if select("#", ...) ~= count then
            guard.reject(name, "arity", player)
            violation(name, "malformed", player)
            return remote.REJECTED
        end

        for i, validator in validators do
            if not validator((select(i, ...))) then
                guard.reject(name, `arg{i}`, player)
                violation(name, "malformed", player)
                return remote.REJECTED
            end
        end

        local ok, result = pcall(fn, player, ...)
        if not ok then
            guard.reject(name, "error", player)
            if not warned[name] then
                warned[name] = true
                warn(`[net] {name} handler failed: {result}`)
            end

            return remote.REJECTED
        end

        return result
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
    guard.on_violation(function(player, _, category, count)
        local limit = if category == "flood" then CONFIG.flood_limit else CONFIG.strike_limit
        if count >= limit and typeof(player) == "Instance" and player:IsA("Player") and player.Parent == players then
            player:Kick(KICK_MESSAGE)
        end
    end)

    players.PlayerRemoving:Connect(function(player)
        counts[player] = nil
        for _, limiter in limiters do
            limiter:forget(player)
        end
    end)
end

return guard
