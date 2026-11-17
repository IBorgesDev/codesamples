--!strict

local http_service = game:GetService("HttpService")
local replicated_storage = game:GetService("ReplicatedStorage")

local coordinator = require(script.Parent.Parent.trade.coordinator)
local cross = require(script.Parent.Parent.trade.cross)
local items = require(replicated_storage.Shared.config.items)
local profiles = require(script.Parent.Parent.data.profiles)
local protocol = require(script.Parent.Parent.trade.protocol)
local trade = require(script.Parent.Parent.trade.service)
local tuning = require(script.Parent.Parent.config.tuning)
local types = require(script.Parent.Parent.trade.types)

const MILLISECONDS = 1000
const SETTLE_TIMEOUT = 30
const WAIT_STEP = 0.1

export type Tracker = {
    saves: () -> number,
    settle: () -> (),
}

local bench = {}

local kinds = {}
for kind in items do
    table.insert(kinds, kind)
end

table.sort(kinds)

function bench.seed(data: types.Data)
    if next(data.items) ~= nil then
        return
    end

    for _ = 1, tuning.profiles.seed_items do
        data.items[http_service:GenerateGUID(false)] = { kind = kinds[math.random(1, #kinds)] }
    end

    data.coins = tuning.profiles.seed_coins
end

function bench.holdings(datas: { types.Data }): (number, number, number)
    local item_count, coins, escrows = 0, 0, 0
    for _, data in datas do
        coins += data.coins
        for _ in data.items do
            item_count += 1
        end

        for _, entry in data.escrow do
            escrows += 1
            coins += entry.coins
            for _ in entry.items do
                item_count += 1
            end
        end

        for _, outgoing in data.outbox do
            coins += outgoing.coins
            for _ in outgoing.items do
                item_count += 1
            end
        end
    end

    return item_count, coins, escrows
end

function bench.duplicates(datas: { types.Data }): number
    local seen: { [string]: boolean } = {}
    local duplicated = 0
    local function visit(item_id: string)
        if seen[item_id] then
            duplicated += 1
        end

        seen[item_id] = true
    end

    for _, data in datas do
        for item_id in data.items do
            visit(item_id)
        end

        for _, entry in data.escrow do
            for item_id in entry.items do
                visit(item_id)
            end
        end

        for _, outgoing in data.outbox do
            for item_id in outgoing.items do
                visit(item_id)
            end
        end
    end

    return duplicated
end

function bench.percentile(values: { number }, p: number): number
    local sorted = table.clone(values)
    table.sort(sorted)

    return sorted[math.max(1, math.ceil(#sorted * p))] or 0
end

function bench.ms(seconds: number): number
    return math.round(seconds * MILLISECONDS)
end

function bench.wall_now(): number
    return DateTime.now().UnixTimestampMillis / 1000
end

function bench.datas(list: { profiles.Loaded }): { types.Data }
    local out = {}
    for _, entry in list do
        table.insert(out, entry.account.data)
    end

    return out
end

function bench.open(keys: { string }, users: { number }): { profiles.Loaded }?
    local opened: { [number]: profiles.Loaded } = {}
    local pending = #keys
    for index, key in keys do
        task.spawn(function()
            local entry = profiles.open(key, users[index])
            if entry then
                protocol.recover(trade.ports(), entry.account)
                bench.seed(entry.account.data)
                opened[index] = entry
            end

            pending -= 1
        end)
    end

    while pending > 0 do
        task.wait()
    end

    local list: { profiles.Loaded } = {}
    for index = 1, #keys do
        local entry = opened[index]
        if entry == nil then
            warn(`[bench] could not open {keys[index]}`)
            bench.close(opened)
            return nil
        end

        table.insert(list, entry)
    end

    return list
end

function bench.close(list: { [number]: profiles.Loaded })
    for _, entry in list do
        entry.profile:EndSession()
    end
end

function bench.track(list: { profiles.Loaded }): Tracker
    local saves = 0
    local in_flight = 0
    for _, entry in list do
        local persist = entry.account.persist
        entry.account.persist = function(durable)
            saves += 1
            in_flight += 1
            local landed = persist(durable)
            in_flight -= 1

            return landed
        end
    end

    return {
        saves = function()
            return saves
        end,
        settle = function()
            local deadline = os.clock() + SETTLE_TIMEOUT
            while in_flight > 0 and os.clock() < deadline do
                task.wait(WAIT_STEP)
            end
        end,
    }
end

function bench.all(tasks: { () -> () })
    local pending = #tasks
    for _, work in tasks do
        task.spawn(function()
            local ok, problem = pcall(function()
                work()
            end)

            if not ok then
                warn(`[bench] task failed: {problem}`)
            end

            pending -= 1
        end)
    end

    while pending > 0 do
        task.wait()
    end
end

function bench.coordinator(): (coordinator.Coordinator, () -> number)
    local coord = coordinator.memory_store()
    local calls = 0
    local wrapped = {}
    for name, fn in coord :: any do
        wrapped[name] = function(...)
            if name ~= "send" then
                calls += 1
            end

            return fn(...)
        end
    end

    return wrapped :: any, function()
        return calls
    end
end

function bench.negotiate(
    coord: coordinator.Coordinator,
    session_id: string,
    a: number,
    b: number,
    item_id: string,
    kind: string
): number?
    local now = bench.wall_now()
    cross.apply(coord, session_id, a, { kind = "add", item_id = item_id, item = { kind = kind } }, now)
    local _, offered = cross.apply(coord, session_id, a, { kind = "coins", amount = 1 }, now)
    if offered == nil then
        return nil
    end

    local version = offered.session.version
    cross.apply(coord, session_id, a, { kind = "accept", version = version }, now)
    local _, accepted =
        cross.apply(coord, session_id, b, { kind = "accept", version = version }, now + tuning.trade.accept_delay)

    return if accepted then accepted.session.lock_at else nil
end

return bench
