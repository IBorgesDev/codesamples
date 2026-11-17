--!strict

local http_service = game:GetService("HttpService")
local replicated_storage = game:GetService("ReplicatedStorage")
local run_service = game:GetService("RunService")
local server_script_service = game:GetService("ServerScriptService")

local aggregator = require(script.Parent.Parent.live_event.aggregator)
local counter = require(script.Parent.Parent.live_event.counter)
local memory_store = require(script.Parent.Parent.live_event.memory_store)
local trace = require(replicated_storage.Shared.util.trace)
local tuning = require(replicated_storage.Shared.config.tuning)

const ATTRIBUTE = "StressTest"
const LIVE_SERVERS = 12
const LIVE_SECONDS = 35
const LIVE_PUBLISH_EVERY = 4
const LIVE_PASS_EVERY = 3
const LIVE_SHARDS = 4
const LIVE_EXPIRATION = 600
const LIVE_DRAIN_ATTEMPTS = 10
const MAX_FISH = 5
const HEARTBEAT = 10
const ORPHAN_AFTER = 30
const LIVE_GROUPS = LIVE_SHARDS // 2

local function wall_now(): number
    return DateTime.now().UnixTimestampMillis / 1000
end

local function percentile(values: { number }, p: number): number
    local sorted = table.clone(values)
    table.sort(sorted)

    return sorted[math.max(1, math.ceil(#sorted * p))] or 0
end

local function live_publishers()
    local event_id = `stress_{string.sub(string.gsub(http_service:GenerateGUID(false), "-", ""), 1, 8)}`
    local spec =
        { id = event_id, kind = "counter", options = { "fish" }, goal = nil, ends_at = nil, shards = LIVE_SHARDS }
    local layout = {
        shards_per_group = 2,
        max_replicas = 2,
        close_grace = 60,
        candidates = 8,
        live_window = tuning.live_event.live_window,
    }
    local options = {
        expiration = LIVE_EXPIRATION,
        read_parallelism = tuning.platform.read_parallelism,
        backoff_base = tuning.live_event.backoff_base,
        backoff_cap = tuning.live_event.backoff_cap,
    }

    local servers = {}
    for index = 1, LIVE_SERVERS do
        table.insert(servers, {
            id = `stress-server-{index}`,
            ports = memory_store.ports(options :: any),
            entry = counter.entry(),
            published = 0,
            failures = 0,
        })
    end

    local leader = memory_store.ports(options :: any)
    local running = true
    local published_total = 0
    local function publish(server: any): boolean
        local entry = counter.copy(server.entry)
        entry.seen = math.floor(wall_now())
        if aggregator.publish(server.ports, spec :: any, layout, server.id, entry) then
            server.published = counter.value(entry).fish or 0
            return true
        end

        server.failures += 1
        return false
    end

    for _, server in servers do
        task.spawn(function()
            task.wait(math.random() * LIVE_PUBLISH_EVERY)
            while running do
                counter.add(server.entry, "fish", math.random(1, MAX_FISH))
                publish(server)
                task.wait(LIVE_PUBLISH_EVERY)
            end
        end)
    end

    local groups = {}
    for group = 1, LIVE_GROUPS do
        groups[group] = { previous = nil }
    end

    local root = { previous = nil, cursor = 0 }
    local lags = {}
    task.spawn(function()
        while running do
            local now = wall_now()
            for group = 1, LIVE_GROUPS do
                aggregator.group_pass(leader, spec :: any, layout, group, groups[group] :: any, now, HEARTBEAT)
            end

            local snapshot =
                aggregator.root_pass(leader, spec :: any, layout, root :: any, now, HEARTBEAT, ORPHAN_AFTER, 1)
            if snapshot then
                local truth = 0
                for _, server in servers do
                    truth += counter.value(server.entry).fish or 0
                end

                table.insert(lags, truth - (snapshot.totals.fish or 0))
            end

            task.wait(LIVE_PASS_EVERY)
        end
    end)

    task.wait(LIVE_SECONDS)
    running = false

    for _, server in servers do
        for _ = 1, LIVE_DRAIN_ATTEMPTS do
            if publish(server) then
                break
            end

            task.wait(tuning.live_event.backoff_base)
        end

        published_total += server.published
    end

    local truth, failures = 0, 0
    for _, server in servers do
        truth += counter.value(server.entry).fish or 0
        failures += server.failures
    end

    local now = wall_now()
    local final = nil
    for _ = 1, LIVE_DRAIN_ATTEMPTS do
        for group = 1, LIVE_GROUPS do
            aggregator.group_pass(leader, spec :: any, layout, group, { previous = nil }, now, 0)
        end

        final =
            aggregator.root_pass(leader, spec :: any, layout, { previous = nil, cursor = 0 }, now, 0, ORPHAN_AFTER, 1)
        if final and (final.totals.fish or 0) == truth then
            break
        end

        task.wait(tuning.live_event.backoff_base)
        now = wall_now()
    end

    trace(
        "stress live",
        `{LIVE_SERVERS} servers publishing to one event for {LIVE_SECONDS} s on the real MemoryStore: `
            .. `caught {truth}, published {published_total}, final total {if final
                then final.totals.fish or 0
                else "none"} `
            .. `({if final and final.totals.fish == truth then "exact" else "MISMATCH"}), `
            .. `{if final then final.live else "?"} live of {if final then final.servers else "?"} servers, `
            .. `{failures} publish calls throttled or failed and retried, `
            .. `fish not yet in the total during the run p50 {percentile(lags, 0.5)} max {percentile(lags, 1)}`
    )
end

return function()
    if run_service:IsStudio() and server_script_service:GetAttribute(ATTRIBUTE) == true then
        task.spawn(function()
            live_publishers()
            trace("stress", "done")
        end)
    end
end
