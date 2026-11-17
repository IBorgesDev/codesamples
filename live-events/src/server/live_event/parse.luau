--!strict

local types = require(script.Parent.types)

type Entry = types.Entry
type Partial = types.Partial
type Shard = types.Shard
type Snapshot = types.Snapshot
type Tally = types.Tally

const LARGEST_COUNT = 2 ^ 53

local parse = {}

local function count(value: unknown): number?
    if type(value) == "number" and value == value and math.abs(value) <= LARGEST_COUNT then
        return value
    end

    return nil
end

local function at_least(value: unknown, minimum: number): number?
    local number = count(value)

    return if number and number >= minimum then number else nil
end

local function state_of(value: unknown): types.State?
    if value == "live" then
        return "live"
    elseif value == "completed" then
        return "completed"
    elseif value == "closed" then
        return "closed"
    end

    return nil
end

local function absent_or(value: unknown, parsed: number?): boolean
    return value == nil or parsed ~= nil
end

function parse.tally(value: unknown): Tally?
    if type(value) ~= "table" then
        return nil
    end

    local tally: Tally = {}
    for option, amount in value :: { [unknown]: unknown } do
        local number = count(amount)
        if type(option) ~= "string" or number == nil then
            return nil
        end

        tally[option] = number
    end

    return tally
end

function parse.snapshot(value: unknown): Snapshot?
    if type(value) ~= "table" then
        return nil
    end

    local raw = value :: { [string]: unknown }
    local state: types.State? = state_of(raw.state)
    local totals = parse.tally(raw.totals)
    local version = at_least(raw.version, 0)
    local servers = at_least(raw.servers, 0)
    local at = at_least(raw.at, 0)
    local completed_at = count(raw.completed_at)
    local ends_at = count(raw.ends_at)
    local live = at_least(raw.live, 0)
    local replicas = if raw.replicas == nil then 1 else at_least(raw.replicas, 1)
    if
        state == nil
        or totals == nil
        or version == nil
        or servers == nil
        or at == nil
        or replicas == nil
        or replicas % 1 ~= 0
        or not absent_or(raw.completed_at, completed_at)
        or not absent_or(raw.ends_at, ends_at)
        or not absent_or(raw.live, live)
    then
        return nil
    end

    return {
        state = state,
        version = version,
        totals = totals,
        completed_at = completed_at,
        ends_at = ends_at,
        servers = servers,
        live = live,
        replicas = replicas,
        at = at,
    }
end

function parse.partial(value: unknown): Partial?
    if type(value) ~= "table" then
        return nil
    end

    local raw = value :: { [string]: unknown }
    local totals = parse.tally(raw.totals)
    local servers = at_least(raw.servers, 0)
    local at = at_least(raw.at, 0)
    local live = at_least(raw.live, 0)
    if totals == nil or servers == nil or at == nil or not absent_or(raw.live, live) then
        return nil
    end

    return { totals = totals, servers = servers, live = live, at = at }
end

function parse.entry(value: unknown): Entry?
    if type(value) ~= "table" then
        return nil
    end

    local raw = value :: { [string]: unknown }
    local plus = parse.tally(raw.plus or {})
    local minus = parse.tally(raw.minus or {})
    local seen = count(raw.seen)
    if plus == nil or minus == nil or not absent_or(raw.seen, seen) then
        return nil
    end

    return { plus = plus, minus = minus, seen = seen }
end

function parse.shard(value: unknown): Shard?
    if type(value) ~= "table" then
        return nil
    end

    local shard: Shard = {}
    for key, raw in value :: { [unknown]: unknown } do
        local entry = parse.entry(raw)
        if type(key) == "string" and entry then
            shard[key] = entry
        end
    end

    return shard
end

return parse
