--!strict

local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")

local remote = require(replicated_storage.Shared.net.remote)
local stat = require(script.Parent.Parent.dev.stats)
local token_bucket = require(replicated_storage.Shared.net.token_bucket)
local trace = require(script.Parent.Parent.util.trace)
local tuning = require(script.Parent.Parent.config.tuning)

export type Validator = (value: unknown) -> boolean
export type Limiter = token_bucket.Limiter

type Offence = "malformed" | "flood" | "decoy"

const CONFIG = tuning.net
const KICK_MESSAGE = "Disconnected: invalid requests"
const GUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
const MAX_USER_ID = 2 ^ 53
const KICK_AT: { [Offence]: number } = table.freeze({
    malformed = CONFIG.strike_limit,
    flood = CONFIG.flood_limit,
    decoy = 1,
})

local guard = {}

local limiters: { Limiter } = {}
local offences: { [Player]: { counts: { [Offence]: number }, since: number } } = {}
local rejected: { [string]: number } = {}
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

function t.integer(min: number, max: number): Validator
    return function(value)
        return type(value) == "number" and finite(value) and value % 1 == 0 and value >= min and value <= max
    end
end

t.user_id = t.integer(1, MAX_USER_ID)

function t.id(value: unknown): boolean
    return type(value) == "string" and string.match(value, GUID) ~= nil
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

local function reject(name: string, reason: string, player: Player)
    local key = `net.{name}.{reason}`
    rejected[key] = (rejected[key] or 0) + 1
    stat(key, rejected[key])
    trace("net", `{name} rejected {player.UserId}: {reason}`)
end

local function offend(name: string, offence: Offence, player: Player)
    reject(name, offence, player)

    local now = os.clock()
    local record = offences[player]
    if record == nil or now - record.since > CONFIG.strike_window then
        record = { counts = {}, since = now }
        offences[player] = record
    end

    local count = (record.counts[offence] or 0) + 1
    record.counts[offence] = count
    stat(`net.violations.{offence}`, count)
    if count >= KICK_AT[offence] then
        player:Kick(KICK_MESSAGE)
    end
end

function guard.limiter(pace: remote.Pace?): Limiter
    local chosen = pace or CONFIG.default_pace
    local limiter = token_bucket.new(chosen.rate, chosen.burst)
    table.insert(limiters, limiter)

    return limiter
end

function guard.handler(name: string, limiter: Limiter?, validators: { Validator }, fn: (Player, ...any) -> ...any)
    local count = #validators
    return function(player: Player, ...: unknown)
        if player.Parent ~= players then
            return
        end

        if not global:take(player) or (limiter and not limiter:take(player)) then
            offend(name, "flood", player)
            return
        end

        if select("#", ...) ~= count then
            offend(name, "malformed", player)
            return
        end

        for i, validator in validators do
            if not validator((select(i, ...))) then
                offend(name, "malformed", player)
                return
            end
        end

        local ok, problem = pcall(fn, player, ...)
        if not ok then
            reject(name, "error", player)
            if not warned[name] then
                warned[name] = true
                warn(`[net] {name} handler failed: {problem}`)
            end
        end
    end
end

function guard.decoy(name: string)
    return function(player: Player)
        if player.Parent == players then
            offend(name, "decoy", player)
        end
    end
end

function guard.start()
    remote.on_stray(function(player, path, stray)
        offend(path, stray, player)
    end)

    players.PlayerRemoving:Connect(function(player)
        offences[player] = nil
        for _, limiter in limiters do
            limiter:forget(player)
        end
    end)
end

return guard
