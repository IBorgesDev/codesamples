--!strict

local http_service = game:GetService("HttpService")
local replicated_storage = game:GetService("ReplicatedStorage")
local run_service = game:GetService("RunService")
local server_script_service = game:GetService("ServerScriptService")

local coordinator = require(script.Parent.Parent.trade.coordinator)
local cross = require(script.Parent.Parent.trade.cross)
local gift = require(script.Parent.Parent.trade.gift)
local gift_service = require(script.Parent.Parent.trade.gift_service)
local profiles = require(script.Parent.Parent.data.profiles)
local protocol = require(script.Parent.Parent.trade.protocol)
local trace = require(replicated_storage.Shared.util.trace)
local trade = require(script.Parent.Parent.trade.service)
local types = require(script.Parent.Parent.trade.types)
local workbench = require(script.Parent.bench)

const SEED_ATTRIBUTE = "TradeSeed"
const BENCHMARK_ATTRIBUTE = "TradeBenchmark"
const CROSS_ATTRIBUTE = "TradeCrossBenchmark"
const GIFT_ATTRIBUTE = "GiftBenchmark"
const BENCH_KEYS = { "bench_1", "bench_2" }
const BENCH_USERS = { 1, 2 }
const LOOP_SERVERS = { "loop_a", "loop_b" }
const DELIVERY_TIMEOUT = 30
const WAIT_STEP = 0.1

local function local_benchmark(bench: { profiles.Loaded }, count: number)
    local tracker = workbench.track(bench)
    local saves = tracker.saves
    local ports = trade.ports()
    local counted = ports.records :: any
    local calls_before = counted.calls()
    local items_before, coins_before = workbench.holdings(workbench.datas(bench))
    local latencies = {}
    local outcomes: { [string]: number } = {}

    for round = 1, count do
        local giver = bench[(round - 1) % 2 + 1]
        local taker = bench[round % 2 + 1]
        local item_id = next(giver.account.data.items)
        if item_id == nil then
            break
        end

        tracker.settle()
        local offer: types.Items = { [item_id] = { kind = giver.account.data.items[item_id].kind } }
        local tx_id = http_service:GenerateGUID(false)
        local started = os.clock()
        local opened = protocol.open(
            ports,
            giver.account,
            tx_id,
            { user_id = giver.user_id, coins = 1, items = offer, ready = false },
            { user_id = taker.user_id, coins = 0, items = {}, ready = false },
            1
        )

        local outcome: string = opened
        if opened == "open" then
            outcome = protocol.prepare(ports, taker.account, tx_id)
            if outcome == "committed" then
                protocol.finalize(ports, giver.account, tx_id)
            end
        end

        table.insert(latencies, os.clock() - started)
        outcomes[outcome] = (outcomes[outcome] or 0) + 1
    end

    tracker.settle()
    local items_after, coins_after, escrows = workbench.holdings(workbench.datas(bench))
    local done = math.max(1, #latencies)
    trace(
        "trade bench",
        `{#latencies} trades on the real DataStore: {outcomes.committed or 0} committed, `
            .. `until both players see the result p50 {workbench.ms(workbench.percentile(latencies, 0.5))} ms, `
            .. `p95 {workbench.ms(workbench.percentile(latencies, 0.95))} ms, `
            .. `{saves() / done} profile saves and {(counted.calls() - calls_before) / done} record calls per trade, `
            .. `items {items_before} -> {items_after}, coins {coins_before} -> {coins_after}, {escrows} escrow(s) left`
    )
end

local function cross_benchmark(bench: { profiles.Loaded }, count: number)
    local tracker = workbench.track(bench)
    local saves = tracker.saves
    local ports = trade.ports()
    local counted = ports.records :: any
    local coord, memory_calls = workbench.coordinator()
    local sent: { [string]: number } = {}
    local hints: { number } = {}
    local connection = coordinator.subscribe(LOOP_SERVERS[2], function(message)
        local at = if type(message.session) == "string" then sent[message.session] else nil
        if at then
            table.insert(hints, os.clock() - at)
        end
    end)

    local records_before, memory_before = counted.calls(), memory_calls()
    local items_before, coins_before = workbench.holdings(workbench.datas(bench))
    local totals, settlements = {}, {}
    local outcomes: { [string]: number } = {}

    for round = 1, count do
        local giver = bench[(round - 1) % 2 + 1]
        local taker = bench[round % 2 + 1]
        local item_id = next(giver.account.data.items)
        if item_id == nil then
            break
        end

        tracker.settle()
        local session_id = http_service:GenerateGUID(false)
        local started = os.clock()
        coord.create(cross.new(session_id, giver.user_id, taker.user_id, LOOP_SERVERS[1], LOOP_SERVERS[2]))
        local kind = giver.account.data.items[item_id].kind
        local lock_at = workbench.negotiate(coord, session_id, giver.user_id, taker.user_id, item_id, kind)
        if lock_at == nil then
            outcomes.not_locked = (outcomes.not_locked or 0) + 1
            continue
        end

        local settling = os.clock()
        local tx_id = http_service:GenerateGUID(false)
        local outcome: string = cross.commit(coord, ports, session_id, giver.account, tx_id, lock_at)
        sent[session_id] = os.clock()
        coord.send(LOOP_SERVERS[2], { kind = "changed", session = session_id })
        if outcome == "open" then
            local _, opened = coord.get(session_id)
            outcome = if opened then cross.prepare(coord, ports, opened, taker.account) or "none" else "none"
            local _, decided = coord.get(session_id)
            if decided then
                cross.resume(coord, ports, decided, giver.account)
            end
        end

        table.insert(totals, os.clock() - started)
        table.insert(settlements, os.clock() - settling)
        outcomes[outcome] = (outcomes[outcome] or 0) + 1
    end

    local deadline = os.clock() + DELIVERY_TIMEOUT
    while #hints < #totals and os.clock() < deadline do
        task.wait(WAIT_STEP)
    end

    if connection then
        connection:Disconnect()
    end

    tracker.settle()
    local items_after, coins_after, escrows = workbench.holdings(workbench.datas(bench))
    local done = math.max(1, #totals)
    trace(
        "trade cross bench",
        `{#totals} cross-server trades on the real MemoryStore and DataStore: {outcomes.committed or 0} committed, `
            .. `negotiation plus settlement p50 {workbench.ms(workbench.percentile(totals, 0.5))} ms p95 {workbench.ms(
                workbench.percentile(totals, 0.95)
            )} ms, `
            .. `settlement p50 {workbench.ms(workbench.percentile(settlements, 0.5))} ms p95 {workbench.ms(
                workbench.percentile(settlements, 0.95)
            )} ms, `
            .. `{(memory_calls() - memory_before) / done} MemoryStore calls, {(counted.calls() - records_before) / done} record calls `
            .. `and {saves() / done} profile saves per trade, {#hints}/{#totals} hints delivered `
            .. `(p50 {workbench.ms(workbench.percentile(hints, 0.5))} ms p95 {workbench.ms(
                workbench.percentile(hints, 0.95)
            )} ms), `
            .. `items {items_before} -> {items_after}, coins {coins_before} -> {coins_after}, {escrows} escrow(s) left`
    )
end

local function gift_benchmark(bench: { profiles.Loaded }, count: number)
    local sender, receiver = bench[1], bench[2]
    gift_service.receive(receiver)
    local items_before, coins_before = workbench.holdings(workbench.datas(bench))
    local latencies = {}
    local sender_key = tostring(sender.user_id)

    local function seen(): number
        return receiver.account.data.gift_seen[sender_key] or 0
    end

    for _ = 1, count do
        local data = sender.account.data
        local item_id = next(data.items)
        local offer: types.Items = if item_id then { [item_id] = data.items[item_id] } else {}
        local tx_id = gift.send(data, sender.user_id, receiver.user_id, 1, offer, os.time())
        if tx_id == nil then
            break
        end

        local seq = data.outbox[tx_id].seq
        local started = os.clock()
        gift_service.deliver(
            sender.account,
            gift_service.reserved(function(_, message)
                return profiles.message_key(BENCH_KEYS[2], message)
            end)
        )

        local deadline = os.clock() + DELIVERY_TIMEOUT
        while seen() < seq and os.clock() < deadline do
            task.wait(WAIT_STEP)
        end

        if seen() >= seq then
            table.insert(latencies, os.clock() - started)
        end
    end

    local items_after, coins_after = workbench.holdings(workbench.datas(bench))
    trace(
        "gift bench",
        `{#latencies}/{count} gifts credited through ProfileStore messages, `
            .. `send to credit p50 {workbench.ms(workbench.percentile(latencies, 0.5))} ms p95 {workbench.ms(
                workbench.percentile(latencies, 0.95)
            )} ms, `
            .. `items {items_before} -> {items_after}, coins {coins_before} -> {coins_after}, `
            .. `{#gift.pending(sender.account.data)} gift(s) still in the outbox`
    )
end

local function run_benchmarks(local_count: number, cross_count: number, gift_count: number)
    local bench = workbench.open(BENCH_KEYS, BENCH_USERS)
    if bench == nil then
        return
    end

    if local_count > 0 then
        local_benchmark(bench, local_count)
    end

    if cross_count > 0 then
        cross_benchmark(bench, cross_count)
    end

    if gift_count > 0 then
        gift_benchmark(bench, gift_count)
    end

    for _, entry in bench do
        entry.profile:EndSession()
    end
end

local function count_of(attribute: string): number
    local value = server_script_service:GetAttribute(attribute)

    return if type(value) == "number" and value > 0 then value else 0
end

return function()
    if not run_service:IsStudio() then
        return
    end

    profiles.on_loaded(function(_, entry)
        if server_script_service:GetAttribute(SEED_ATTRIBUTE) == true then
            workbench.seed(entry.account.data)
        end
    end)

    local local_count = count_of(BENCHMARK_ATTRIBUTE)
    local cross_count = count_of(CROSS_ATTRIBUTE)
    local gift_count = count_of(GIFT_ATTRIBUTE)
    if local_count + cross_count + gift_count > 0 then
        task.spawn(run_benchmarks, local_count, cross_count, gift_count)
    end
end
