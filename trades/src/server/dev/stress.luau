--!strict

local http_service = game:GetService("HttpService")
local replicated_storage = game:GetService("ReplicatedStorage")
local run_service = game:GetService("RunService")
local server_script_service = game:GetService("ServerScriptService")

local cross = require(script.Parent.Parent.trade.cross)
local gift = require(script.Parent.Parent.trade.gift)
local gift_service = require(script.Parent.Parent.trade.gift_service)
local profiles = require(script.Parent.Parent.data.profiles)
local protocol = require(script.Parent.Parent.trade.protocol)
local records = require(script.Parent.Parent.trade.records)
local trace = require(replicated_storage.Shared.util.trace)
local trade = require(script.Parent.Parent.trade.service)
local tuning = require(replicated_storage.Shared.config.tuning)
local types = require(script.Parent.Parent.trade.types)
local workbench = require(script.Parent.bench)

const ATTRIBUTE = "StressTest"
const PLAYERS = 12
const USER_BASE = 1000
const GIFTS_PER_SENDER = 2
const GIFT_SENDERS = 6
const DELIVERY_TIMEOUT = 60
const WAIT_STEP = 0.2
const CONTESTED_OWNER = 1
const FAN_HUB = 5
const FAN_FIRST = 6
const FAN_LAST = 8
const CROSS_PAIRS = 4
const LOCK_RACERS = 3

type Loaded = profiles.Loaded
type Tally = { [string]: number }

local function side(entry: Loaded, coins: number, offer: types.Items): types.Side
    return { user_id = entry.user_id, coins = coins, items = offer, ready = false }
end

local function first_item(entry: Loaded, skip: { [string]: boolean }?): (string?, types.Items)
    for item_id, item in entry.account.data.items do
        if not (skip and skip[item_id]) then
            return item_id, { [item_id] = { kind = item.kind } }
        end
    end

    return nil, {}
end

local function trade_once(giver: Loaded, taker: Loaded, offer: types.Items, tally: Tally, latencies: { number })
    if records.budget() < tuning.trade.min_update_budget then
        tally.busy = (tally.busy or 0) + 1
        return
    end

    local ports = trade.ports()
    local tx_id = http_service:GenerateGUID(false)
    local started = os.clock()
    local opened, why = protocol.open(ports, giver.account, tx_id, side(giver, 1, offer), side(taker, 0, {}), 1)
    local outcome: string = opened
    if opened == "open" then
        local prepared, prepared_why = protocol.prepare(ports, taker.account, tx_id)
        outcome = prepared
        why = prepared_why
        if prepared == "committed" then
            protocol.finalize(ports, giver.account, tx_id)
        end
    end

    table.insert(latencies, os.clock() - started)
    local key = if outcome ~= "committed" and why then `{outcome} ({why})` else outcome
    tally[key] = (tally[key] or 0) + 1
end

local function describe(tally: Tally): string
    local parts = {}
    for outcome, count in tally do
        table.insert(parts, `{count} {outcome}`)
    end

    table.sort(parts)

    return table.concat(parts, ", ")
end

local function trades(list: { Loaded })
    local tracker = workbench.track(list)
    local datas = workbench.datas(list)
    local items_before, coins_before = workbench.holdings(datas)

    local parallel: Tally, parallel_latency = {}, {}
    local tasks = {}
    for pair = 1, PLAYERS // 2 do
        local giver, taker = list[2 * pair - 1], list[2 * pair]
        local _, offer = first_item(giver)
        table.insert(tasks, function()
            trade_once(giver, taker, offer, parallel, parallel_latency)
        end)
    end

    workbench.all(tasks)
    tracker.settle()

    local contested: Tally, contested_latency = {}, {}
    local owner = list[CONTESTED_OWNER]
    local _, prize = first_item(owner)
    workbench.all({
        function()
            trade_once(owner, list[CONTESTED_OWNER + 1], prize, contested, contested_latency)
        end,
        function()
            trade_once(owner, list[CONTESTED_OWNER + 2], prize, contested, contested_latency)
        end,
    })
    tracker.settle()

    local fan: Tally, fan_latency = {}, {}
    local hub = list[FAN_HUB]
    local taken: { [string]: boolean } = {}
    local fan_tasks = {}
    for index = FAN_FIRST, FAN_LAST do
        local item_id, offer = first_item(hub, taken)
        if item_id then
            taken[item_id] = true
            table.insert(fan_tasks, function()
                trade_once(hub, list[index], offer, fan, fan_latency)
            end)
        end
    end

    workbench.all(fan_tasks)
    tracker.settle()

    for _, entry in list do
        protocol.recover(trade.ports(), entry.account)
    end

    tracker.settle()
    local items_after, coins_after, escrows = workbench.holdings(datas)
    local all_latency = table.clone(parallel_latency)
    table.move(fan_latency, 1, #fan_latency, #all_latency + 1, all_latency)
    trace(
        "stress trades",
        `{PLAYERS // 2} at once: {describe(parallel)}; same item in 2 at once: {describe(contested)}; `
            .. `one player in {#fan_tasks} at once: {describe(fan)}; `
            .. `p50 {workbench.ms(workbench.percentile(all_latency, 0.5))} ms p95 {workbench.ms(
                workbench.percentile(all_latency, 0.95)
            )} ms; `
            .. `items {items_before} -> {items_after}, coins {coins_before} -> {coins_after}, `
            .. `{workbench.duplicates(datas)} duplicated item(s), {escrows} escrow(s) left`
    )
end

local function cross_once(coord: any, a: Loaded, b: Loaded, tally: Tally, latencies: { number }, racers: number)
    local item_id, offer = first_item(a)
    if item_id == nil then
        tally.no_item = (tally.no_item or 0) + 1
        return
    end

    local ports = trade.ports()
    local session_id = http_service:GenerateGUID(false)
    local started = os.clock()
    coord.create(cross.new(session_id, a.user_id, b.user_id, "stress_a", "stress_b"))
    local lock_at = workbench.negotiate(coord, session_id, a.user_id, b.user_id, item_id, offer[item_id].kind)
    if lock_at == nil then
        tally.not_locked = (tally.not_locked or 0) + 1
        return
    end

    local opens = 0
    local race = {}
    for _ = 1, racers do
        table.insert(race, function()
            local result = cross.commit(coord, ports, session_id, a.account, http_service:GenerateGUID(false), lock_at)
            if result == "open" then
                opens += 1
            end
        end)
    end

    workbench.all(race)
    if opens ~= 1 then
        tally[`locked_{opens}_times`] = (tally[`locked_{opens}_times`] or 0) + 1
    end

    local _, opened = coord.get(session_id)
    local outcome = if opened then cross.prepare(coord, ports, opened, b.account) or "none" else "none"
    local _, decided = coord.get(session_id)
    if decided then
        cross.resume(coord, ports, decided, a.account)
    end

    table.insert(latencies, os.clock() - started)
    tally[outcome] = (tally[outcome] or 0) + 1
end

local function cross_trades(list: { Loaded })
    local tracker = workbench.track(list)
    local datas = workbench.datas(list)
    local items_before, coins_before = workbench.holdings(datas)
    local coord = workbench.coordinator()
    local tally: Tally, latencies = {}, {}
    local tasks = {}
    for pair = 1, CROSS_PAIRS do
        local a, b = list[2 * pair - 1], list[2 * pair]
        local racers = if pair == 1 then LOCK_RACERS else 1
        table.insert(tasks, function()
            cross_once(coord, a, b, tally, latencies, racers)
        end)
    end

    workbench.all(tasks)
    tracker.settle()
    for _, entry in list do
        protocol.recover(trade.ports(), entry.account)
    end

    tracker.settle()
    local items_after, coins_after, escrows = workbench.holdings(datas)
    trace(
        "stress cross",
        `{CROSS_PAIRS} cross-server trades at once, one of them with {LOCK_RACERS} servers racing to lock it: {describe(
            tally
        )}; `
            .. `p50 {workbench.ms(workbench.percentile(latencies, 0.5))} ms p95 {workbench.ms(
                workbench.percentile(latencies, 0.95)
            )} ms; `
            .. `items {items_before} -> {items_after}, coins {coins_before} -> {coins_after}, `
            .. `{workbench.duplicates(datas)} duplicated item(s), {escrows} escrow(s) left`
    )
end

local function gifts(list: { Loaded }, receiver_key: string)
    local receiver = list[1]
    gift_service.receive(receiver)
    local senders = {}
    for index = 2, GIFT_SENDERS + 1 do
        table.insert(senders, list[index])
    end

    local datas = workbench.datas(list)
    local items_before, coins_before = workbench.holdings(datas)
    local receiver_coins = receiver.account.data.coins
    local sent_coins = 0
    local finals: { [string]: number } = {}
    local tasks = {}
    local deliveries = 0
    for _, sender in senders do
        local data = sender.account.data
        for round = 1, GIFTS_PER_SENDER do
            local _, offer = first_item(sender)
            local items: types.Items = if round == 1 then offer else {}
            local real: types.Items = {}
            for item_id in items do
                real[item_id] = data.items[item_id]
            end

            if gift.send(data, sender.user_id, receiver.user_id, 1, real, os.time()) then
                sent_coins += 1
            end
        end

        finals[tostring(sender.user_id)] = data.gift_seq
        table.insert(tasks, function()
            gift_service.deliver(sender.account, function(_, message)
                profiles.message_key(receiver_key, message)
                deliveries += 1
                return profiles.message_key(receiver_key, message)
            end)
        end)
    end

    local started = os.clock()
    workbench.all(tasks)
    local deadline = os.clock() + DELIVERY_TIMEOUT
    local function all_credited(): boolean
        for sender_key, seq in finals do
            if (receiver.account.data.gift_seen[sender_key] or 0) < seq then
                return false
            end
        end

        return true
    end

    while not all_credited() and os.clock() < deadline do
        task.wait(WAIT_STEP)
    end

    local items_after, coins_after = workbench.holdings(datas)
    local outbox = 0
    for _, sender in senders do
        outbox += #gift.pending(sender.account.data)
    end

    trace(
        "stress gifts",
        `{GIFT_SENDERS} senders x {GIFTS_PER_SENDER} gifts to one player at once, each message sent twice: `
            .. `all credited {all_credited()} in {workbench.ms(os.clock() - started)} ms, `
            .. `receiver coins +{receiver.account.data.coins - receiver_coins} for {sent_coins} sent, {deliveries} duplicate sends, `
            .. `items {items_before} -> {items_after}, coins {coins_before} -> {coins_after}, `
            .. `{workbench.duplicates(datas)} duplicated item(s), {outbox} gift(s) still in outboxes`
    )
end

local function run()
    local keys, users = {}, {}
    for index = 1, PLAYERS do
        table.insert(keys, `stress_{index}`)
        table.insert(users, USER_BASE + index)
    end

    local list = workbench.open(keys, users)
    if list == nil then
        return
    end

    trace("stress", `{PLAYERS} test profiles open, budget {records.budget()} record updates`)
    trades(list)
    cross_trades(list)
    gifts(list, keys[1])
    workbench.close(list)
    trace("stress", "done")
end

return function()
    if run_service:IsStudio() and server_script_service:GetAttribute(ATTRIBUTE) == true then
        task.spawn(run)
    end
end
