--!strict

local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")
local run_service = game:GetService("RunService")
local server_script_service = game:GetService("ServerScriptService")

local aggregator = require(script.Parent.aggregator)
local archive = require(script.Parent.archive)
local ballot = require(script.Parent.ballot)
local breaker = require(script.Parent.Parent.net.breaker)
local catalog = require(replicated_storage.Shared.config.live_events)
local counter = require(script.Parent.counter)
local guard = require(script.Parent.Parent.net.guard)
local http = require(script.Parent.http)
local memory_store = require(script.Parent.memory_store)
local net = require(replicated_storage.Shared.net)
local planner = require(script.Parent.planner)
local profiles = require(script.Parent.Parent.data.profiles)
local reward = require(script.Parent.reward)
local server_id = require(script.Parent.Parent.net.identity)
local trace = require(replicated_storage.Shared.util.trace)
local tuning = require(replicated_storage.Shared.config.tuning)
local types = require(script.Parent.types)

const CONFIG = tuning.live_event
const BACKEND_ATTRIBUTE = "LiveEventBackend"
const DISABLED_ATTRIBUTE = "LiveEventDisabled"

type Event = {
    spec: types.Spec,
    entry: types.Entry,
    sent: types.Entry,
    sent_at: number,
    snapshot: types.Snapshot?,
    root: aggregator.Root,
    group: aggregator.Group,
    dirty: boolean,
    floor: types.Tally,
    polled_at: number,
    passed_at: number,
    archived: types.Snapshot?,
    archived_at: number,
    reward_coins: number?,
}

export type Activity = "contribution" | "vote" | "reward"

local live = {}

local listeners: { (Activity, Player?, string, string?, number) -> () } = {}
local voting: { [Player]: boolean } = {}

local events: { [string]: Event } = {}
local running = false
local backend_name = CONFIG.backend
local http_breaker = breaker.new(CONFIG.breaker_failures, CONFIG.breaker_cooldown)
local held: { [string]: number } = {}
local event_count = 0

local layout: types.Layout = {
    shards_per_group = CONFIG.shards_per_group,
    max_replicas = CONFIG.max_replicas,
    close_grace = CONFIG.close_grace,
    candidates = CONFIG.root_candidates,
    live_window = CONFIG.live_window,
}

local function now(): number
    return DateTime.now().UnixTimestampMillis / 1000
end

local ports = memory_store.ports({
    expiration = CONFIG.expiration,
    read_parallelism = tuning.platform.read_parallelism,
    backoff_base = CONFIG.backoff_base,
    backoff_cap = CONFIG.backoff_cap,
})
local http_backend = http.backend({ url_secret = "events_url", token_secret = "events_token" }, now)
local archive_store = archive.open(
    if run_service:IsStudio() then CONFIG.archive_store .. tuning.profiles.studio_suffix else CONFIG.archive_store
)

local function notify(activity: Activity, player: Player?, event_id: string, option: string?, amount: number)
    for _, listener in listeners do
        task.spawn(listener, activity, player, event_id, option, amount)
    end
end

function live.on_activity(listener: (Activity, Player?, string, string?, number) -> ())
    table.insert(listeners, listener)
end

local function apply(event: Event, snapshot: types.Snapshot?)
    if aggregator.newer(event.snapshot, snapshot) then
        event.snapshot = snapshot
        event.dirty = true
    end
end

function live.display(event_id: string): types.Snapshot?
    local event = events[event_id]
    if not event then
        return nil
    end

    local base: types.Snapshot = event.snapshot
        or event.archived
        or {
            state = "live",
            version = 0,
            totals = {},
            completed_at = nil,
            ends_at = event.spec.ends_at,
            servers = 1,
            replicas = 1,
            at = now(),
        }

    local totals = table.clone(base.totals)
    local already = if event.snapshot then counter.value(event.sent) else {}
    for option, value in counter.value(event.entry) do
        totals[option] = (totals[option] or 0) + value - (already[option] or 0)
    end

    if event.spec.kind == "counter" then
        for option, value in totals do
            local floor = math.max(event.floor[option] or 0, value)
            event.floor[option] = floor
            totals[option] = floor
        end
    end

    local display = table.clone(base)
    display.totals = totals

    return display
end

local function accepting(event: Event, option: string): boolean
    if not table.find(event.spec.options, option) then
        return false
    end

    local snapshot = event.snapshot
    if snapshot and snapshot.state == "closed" then
        return false
    end

    local ends_at = event.spec.ends_at

    return ends_at == nil or now() < ends_at
end

local function push_mine(player: Player)
    local loaded = profiles.get(player)
    if loaded == nil then
        return
    end

    local data = loaded.account.data
    local votes = {}
    for event_id, cast in data.live_votes do
        votes[event_id] = { option = cast.option, here = cast.server == server_id }
    end

    local rewards = {}
    for event_id in data.live_rewards do
        rewards[event_id] = true
    end

    net.live.mine:set(player, { votes = votes, rewards = rewards })
end

function live.contribute(event_id: string, option: string, amount: number, player: Player?): boolean
    local event = events[event_id]
    if not event or event.spec.kind ~= "counter" or amount <= 0 or amount % 1 ~= 0 or not accepting(event, option) then
        return false
    end

    counter.add(event.entry, option, amount)
    event.dirty = true
    notify("contribution", player, event_id, option, amount)

    return true
end

function live.vote(player: Player, event_id: string, option: string): boolean
    local event = events[event_id]
    local loaded = profiles.get(player)
    if not event or event.spec.kind ~= "vote" or loaded == nil or voting[player] or not accepting(event, option) then
        return false
    end

    local data = loaded.account.data
    local previous = data.live_votes[event_id]
    local decision = ballot.decide(previous, option, server_id)
    if decision == "same" then
        return true
    end

    if decision == "foreign" then
        return false
    end

    voting[player] = true
    data.live_votes[event_id] = { option = option, server = server_id }
    local landed = loaded.account.persist(function(saved)
        local stored = saved.live_votes[event_id]
        return stored ~= nil and stored.option == option and stored.server == server_id
    end)
    voting[player] = nil

    if not landed then
        data.live_votes[event_id] = previous
        return false
    end

    ballot.count(event.entry, previous, option)
    event.dirty = true
    notify("vote", player, event_id, option, 1)
    push_mine(player)

    return true
end

local function grant_rewards()
    for event_id, event in events do
        local coins = event.reward_coins
        if coins == nil or not reward.reached(event.snapshot or event.archived) then
            continue
        end

        for _, player in players:GetPlayers() do
            local loaded = profiles.get(player)
            if loaded and reward.grant(loaded.account.data, event_id, coins, os.time()) then
                trace("live", `{event_id} reward for {player.UserId}`)
                notify("reward", player, event_id, nil, coins)
                push_mine(player)
            end
        end
    end
end

local function restore(event_id: string, event: Event)
    local ok, archived = archive_store.read(event_id)
    if not ok or archived == nil then
        return
    end

    event.archived = archived
    for option, value in archive.floor(event.spec.kind, archived) do
        event.floor[option] = math.max(event.floor[option] or 0, value)
    end

    event.dirty = true
end

local function due(event: Event, at: number): boolean
    return not counter.dominates(event.sent, event.entry) or at - event.sent_at >= CONFIG.heartbeat
end

local function flush_memory_store(at: number)
    for event_id, event in events do
        if due(event, at) then
            local entry = counter.copy(event.entry)
            entry.seen = math.floor(at)
            if aggregator.publish(ports, event.spec, layout, server_id, entry) then
                event.sent = entry
                event.sent_at = at
            end
        end
    end
end

local function flush_http(at: number, sync: boolean)
    if not http_breaker:allow() then
        return
    end

    local entries = {}
    for event_id, event in events do
        if due(event, at) then
            entries[event_id] = counter.copy(event.entry)
        end
    end

    if next(entries) == nil then
        return
    end

    local ok, snapshots = http_backend.publish(server_id, entries, sync)
    if not ok then
        http_breaker:failure()
        trace("live", `http publish failed, breaker {http_breaker:state()}`)
        return
    end

    http_breaker:success()
    for event_id, entry in entries do
        local event = events[event_id]
        event.sent = entry
        event.sent_at = at
        apply(event, if snapshots then snapshots[event_id] else nil)
    end
end

local function flush(final: boolean?)
    if backend_name == "http" then
        flush_http(now(), final == true)
    else
        flush_memory_store(now())
    end
end

local function hold(event_id: string, role: string, ttl: number): boolean
    local key = `{event_id}|{role}`
    local since = held[key]
    if since and now() - since < ttl / 2 then
        return true
    end

    if ports.lease.acquire(event_id, role, server_id, ttl) then
        held[key] = now()
        return true
    end

    held[key] = nil

    return false
end

local function aggregate()
    local at = now()
    for event_id, event in events do
        local population = aggregator.population(event.snapshot)
        local ccu = math.max(1, population) * math.max(1, #players:GetPlayers())
        local interval = planner.pass_interval(ccu, event_count, math.min(event.spec.shards, layout.shards_per_group))
        local ttl = math.max(CONFIG.lease_seconds, interval * CONFIG.lease_passes)

        if at - event.passed_at < interval - CONFIG.aggregate_interval / 2 then
            continue
        end

        event.passed_at = at
        local stale_for = if event.snapshot then at - event.snapshot.at else 0
        local contenders = planner.max_contenders()
        local root_wanted = aggregator.widened(layout.candidates, stale_for, CONFIG.widen_every, contenders)
        local group_wanted = aggregator.widened(CONFIG.group_candidates, stale_for, CONFIG.widen_every, contenders)
        local groups = aggregator.groups(event.spec, layout)
        local group = aggregator.group_of(aggregator.shard_of(server_id, event.spec.shards), layout)
        local group_role = aggregator.group_role(group)

        if
            aggregator.candidate(server_id, group_role, population / groups, group_wanted)
            and hold(event_id, group_role, ttl)
        then
            local _, why =
                aggregator.group_pass(ports, event.spec, layout, group, event.group, now(), CONFIG.group_heartbeat)
            if why then
                trace("live", `{event_id} group {group} pass: {why}`)
            end
        else
            event.group = { previous = nil }
        end

        local root_role = aggregator.root_role()
        if aggregator.candidate(server_id, root_role, population, root_wanted) and hold(event_id, root_role, ttl) then
            local snapshot, why = aggregator.root_pass(
                ports,
                event.spec,
                layout,
                event.root,
                now(),
                CONFIG.total_heartbeat,
                CONFIG.orphan_after,
                CONFIG.max_orphans
            )
            if why then
                trace("live", `{event_id} root pass: {why}`)
            end

            apply(event, snapshot)
            if snapshot and at - event.archived_at >= CONFIG.archive_interval then
                event.archived_at = at
                task.spawn(archive_store.write, event_id, event.spec.kind, snapshot)
            end
        else
            event.root = { previous = nil, cursor = 0 }
        end
    end
end

local function poll()
    local at = now()
    for event_id, event in events do
        local snapshot = event.snapshot
        local replicas = if snapshot then snapshot.replicas else 1
        local spacing = planner.poll_interval(aggregator.population(snapshot), replicas)
        if (snapshot == nil or at - snapshot.at > CONFIG.stale_after) and at - event.polled_at >= spacing then
            event.polled_at = at
            local ok, current = ports.totals.read(event_id, aggregator.replica_of(server_id, replicas))
            if ok then
                apply(event, current)
            end
        end
    end
end

local function push()
    for event_id, event in events do
        if event.dirty then
            event.dirty = false
            local display = live.display(event_id)
            if display then
                net.live.progress:fire_all(event_id, display.state, display.totals, aggregator.population(display))
            end
        end
    end
end

local function every(interval: number, jitter: number, step: () -> ())
    task.spawn(function()
        while running do
            task.wait(interval + math.random() * jitter)
            local ok, err = pcall(step :: any)
            if not ok then
                warn(`[live] {err}`)
            end
        end
    end)
end

local function subscribe(event: Event)
    task.spawn(function()
        while
            running
            and memory_store.subscribe(event.spec.id, function(snapshot)
                    apply(event, snapshot)
                end)
                == nil
        do
            task.wait(CONFIG.subscribe_retry)
        end
    end)
end

function live.server_id(): string
    return server_id
end

function live.start()
    if run_service:IsStudio() and server_script_service:GetAttribute(DISABLED_ATTRIBUTE) == true then
        trace("live", "disabled by attribute")
        return
    end

    running = true
    backend_name = server_script_service:GetAttribute(BACKEND_ATTRIBUTE) or CONFIG.backend

    for _, definition in catalog do
        local event: Event = {
            spec = {
                id = definition.id,
                kind = definition.kind,
                options = definition.options,
                goal = definition.goal,
                ends_at = definition.ends_at,
                shards = definition.shards,
            },
            entry = counter.entry(),
            sent = counter.entry(),
            sent_at = 0,
            snapshot = nil,
            root = { previous = nil, cursor = 0 },
            group = { previous = nil },
            dirty = false,
            floor = {},
            polled_at = 0,
            passed_at = 0,
            archived = nil,
            archived_at = 0,
            reward_coins = definition.reward_coins,
        }
        events[definition.id] = event
        event_count += 1
        task.spawn(restore, definition.id, event)

        if backend_name == "memory_store" then
            subscribe(event)
        end
    end

    local t = guard.t
    net.live.vote:on(
        guard.handler(
            "live.vote",
            guard.limiter(1, 3),
            { t.string(48), t.string(32) },
            function(player, event_id: string, option: string)
                return live.vote(player, event_id, option)
            end
        )
    )

    players.PlayerAdded:Connect(function(player)
        local list = {}
        for event_id in events do
            local display = live.display(event_id)
            if display then
                table.insert(list, {
                    id = event_id,
                    state = display.state,
                    totals = display.totals,
                    servers = aggregator.population(display),
                })
            end
        end

        net.live.sync:fire(player, list)
    end)

    if backend_name == "http" then
        every(CONFIG.http_flush_interval, CONFIG.flush_jitter, flush)
    else
        every(CONFIG.flush_interval, CONFIG.flush_jitter, flush)
        every(CONFIG.aggregate_interval, 0, aggregate)
        every(CONFIG.poll_interval, CONFIG.flush_jitter, poll)
    end

    every(CONFIG.push_interval, 0, push)
    every(CONFIG.reward_interval, 0, grant_rewards)

    players.PlayerRemoving:Connect(function(player)
        voting[player] = nil
    end)

    profiles.on_loaded(function(player)
        push_mine(player)
    end)

    game:BindToClose(function()
        running = false
        local done = false
        task.spawn(function()
            flush(true)
            done = true
        end)

        local deadline = os.clock() + CONFIG.shutdown_flush_timeout
        while not done and os.clock() < deadline do
            task.wait()
        end
    end)

    trace("live", `started server {server_id} on {backend_name}`)
end

return live
