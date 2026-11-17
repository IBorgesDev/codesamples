--!strict

local data_store_service = game:GetService("DataStoreService")
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
local store_name = require(script.Parent.Parent.data.store_name)
local trace = require(script.Parent.Parent.util.trace)
local tuning = require(script.Parent.Parent.config.tuning)
local types = require(script.Parent.types)

const CONFIG = tuning.live_event
const BACKEND_ATTRIBUTE = "LiveEventBackend"
const DISABLED_ATTRIBUTE = "LiveEventDisabled"
const STUDIO = run_service:IsStudio()
const EVENT_ID_BYTES = 48
const OPTION_BYTES = 32

type Vote = {
    user_id: number,
    cast: ballot.Ballot,
}

type Event = {
    spec: types.Spec,
    reward_coins: number?,
    entry: types.Entry,
    sent: types.Entry,
    sent_at: number,
    votes: { [string]: Vote },
    snapshot: types.Snapshot?,
    archived: types.Snapshot?,
    archived_at: number,
    shown_floor: types.Tally,
    changed: boolean,
    polled_at: number,
    group: aggregator.Group,
    group_passed_at: number,
    root: aggregator.Root,
    root_passed_at: number,
    root_running: boolean,
    undersized: boolean,
}

local live = {}

local voting: { [Player]: boolean } = {}
local events: { [string]: Event } = {}
local event_count = 0
local running = false
local backend_name = CONFIG.backend
local http_breaker = breaker.new(CONFIG.breaker_failures, CONFIG.breaker_cooldown)
local lease_renewal: { [string]: number } = {}
local warned: { [string]: boolean } = {}

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
local http_backend = http.backend({ url_secret = CONFIG.url_secret, token_secret = CONFIG.token_secret }, now)
local archive_store = archive.open(store_name(CONFIG.archive_store))

local function warn_once(key: string, message: string)
    if not warned[key] then
        warned[key] = true
        warn(`[live] {message}`)
    end
end

local function each_event(step_name: string, step: (event_id: string, event: Event) -> ...any)
    for event_id, event in events do
        local ok, problem = pcall(step, event_id, event)
        if not ok then
            warn_once(`{step_name}:{event_id}`, `{step_name} failed for {event_id}: {problem}`)
        end
    end
end

local function adopt(event: Event, snapshot: types.Snapshot?)
    if aggregator.newer(event.snapshot, snapshot) then
        event.snapshot = snapshot
        event.changed = true
    end
end

local function unaggregated(event: Event): types.Snapshot
    return {
        state = "live",
        version = 0,
        totals = {},
        completed_at = nil,
        ends_at = event.spec.ends_at,
        servers = 1,
        replicas = 1,
        at = now(),
    }
end

function live.display(event_id: string): types.Snapshot?
    local event = events[event_id]
    if not event then
        return nil
    end

    local base = event.snapshot or event.archived or unaggregated(event)
    local totals = table.clone(base.totals)
    local counted = if event.snapshot then counter.value(event.sent) else {}
    for option, value in counter.value(event.entry) do
        totals[option] = (totals[option] or 0) + value - (counted[option] or 0)
    end

    for _, vote in event.votes do
        counter.sum(totals, counter.value(ballot.entry(vote.cast)))
    end

    if event.spec.kind == "counter" then
        for option, value in totals do
            local floor = math.max(event.shown_floor[option] or 0, value)
            event.shown_floor[option] = floor
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
        votes[event_id] = { option = cast.option, changeable = cast.plus ~= nil }
    end

    local rewards = {}
    for event_id in data.live_rewards do
        rewards[event_id] = true
    end

    net.live.mine:set(player, { votes = votes, rewards = rewards })
end

function live.contribute(event_id: string, option: string, amount: number): boolean
    local event = events[event_id]
    if not event or event.spec.kind ~= "counter" or amount <= 0 or amount % 1 ~= 0 or not accepting(event, option) then
        return false
    end

    counter.add(event.entry, option, amount)
    event.changed = true

    return true
end

local function queue_vote(event: Event, user_id: number, cast: ballot.Ballot)
    event.votes[counter.voter_key(user_id)] = { user_id = user_id, cast = cast }
    event.changed = true
end

local function has_save_budget(): boolean
    local budget = data_store_service:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)

    return budget >= CONFIG.vote_min_budget
end

function live.vote(player: Player, event_id: string, option: string): boolean
    local event = events[event_id]
    local loaded = profiles.get(player)
    if not event or event.spec.kind ~= "vote" or loaded == nil or voting[player] or not accepting(event, option) then
        return false
    end

    local data = loaded.account.data
    local previous = data.live_votes[event_id]
    local decision = ballot.decide(previous, option)
    if decision == "same" then
        return true
    end

    if decision == "locked" or not has_save_budget() then
        return false
    end

    voting[player] = true
    local cast = ballot.next(previous, option)
    data.live_votes[event_id] = cast
    local ok, landed = pcall(loaded.account.persist, function(saved)
        return ballot.same(saved.live_votes[event_id], cast)
    end)
    voting[player] = nil

    if not ok or not landed then
        data.live_votes[event_id] = previous
        return false
    end

    queue_vote(event, player.UserId, cast)
    push_mine(player)

    return true
end

local function grant_reward(event_id: string, event: Event)
    local coins = event.reward_coins
    if coins == nil or not reward.reached(event.spec.goal, event.snapshot or event.archived) then
        return
    end

    for _, player in players:GetPlayers() do
        local loaded = profiles.get(player)
        if loaded and reward.grant(loaded.account.data, event_id, coins, os.time()) then
            trace("live", `{event_id} reward for {player.UserId}`)
            push_mine(player)
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
        event.shown_floor[option] = math.max(event.shown_floor[option] or 0, value)
    end

    event.changed = true
end

local function publish_due(event: Event, at: number): boolean
    return not counter.dominates(event.sent, event.entry) or at - event.sent_at >= CONFIG.heartbeat
end

local function vote_landed(event: Event, event_id: string, key: string, vote: Vote)
    if event.votes[key] == vote then
        event.votes[key] = nil
    end

    local player = players:GetPlayerByUserId(vote.user_id)
    local loaded = if player then profiles.get(player) else nil
    local stored = if loaded then loaded.account.data.live_votes[event_id] else nil
    if stored and ballot.same(stored, vote.cast) then
        stored.published = true
    end
end

local function queue_unpublished(player: Player)
    local loaded = profiles.get(player)
    if loaded == nil then
        return
    end

    for event_id, cast in loaded.account.data.live_votes do
        local event = events[event_id]
        if event and cast.plus ~= nil and cast.published ~= true then
            queue_vote(event, player.UserId, cast)
        end
    end
end

local function flush_to_memory_store(event_id: string, event: Event)
    local at = now()
    if publish_due(event, at) then
        local entry = counter.copy(event.entry)
        entry.seen = math.floor(at)
        if aggregator.publish(ports, event.spec, layout, server_id, entry) then
            event.sent = entry
            event.sent_at = at
        end
    end

    for key, vote in table.clone(event.votes) do
        if aggregator.publish(ports, event.spec, layout, key, ballot.entry(vote.cast)) then
            vote_landed(event, event_id, key, vote)
        end
    end
end

local function http_answered(published: types.Published): boolean
    if published == "sent" then
        http_breaker:success()
    elseif published == "failed" then
        http_breaker:failure()
        trace("live", `http publish failed, breaker {http_breaker:state()}`)
    end

    return published == "sent"
end

local function flush_counters_over_http(at: number, urgent: boolean): boolean
    local entries = {}
    for event_id, event in events do
        if publish_due(event, at) then
            entries[event_id] = counter.copy(event.entry)
        end
    end

    if next(entries) == nil then
        return true
    end

    local published: types.Published, landed = http_backend.publish(server_id, entries, urgent)
    for event_id, snapshot in landed do
        local event = events[event_id]
        event.sent = entries[event_id]
        event.sent_at = at
        adopt(event, snapshot)
    end

    return http_answered(published)
end

local function flush_votes_over_http(urgent: boolean)
    for event_id, event in events do
        for key, vote in table.clone(event.votes) do
            local published: types.Published, landed =
                http_backend.publish(key, { [event_id] = ballot.entry(vote.cast) }, urgent)
            if landed[event_id] then
                vote_landed(event, event_id, key, vote)
            end

            if not http_answered(published) then
                return
            end
        end
    end
end

local function flush(urgent: boolean)
    if backend_name ~= "http" then
        each_event("flush", flush_to_memory_store)
        return
    end

    if (urgent or http_breaker:allow()) and flush_counters_over_http(now(), urgent) then
        flush_votes_over_http(urgent)
    end
end

local function holds_lease(event_id: string, role: string, ttl: number): boolean
    local key = `{event_id}|{role}`
    local renew_at = lease_renewal[key]
    if renew_at and now() < renew_at then
        return true
    end

    if ports.lease.acquire(event_id, role, server_id, ttl) then
        lease_renewal[key] = now() + ttl / 2
        return true
    end

    lease_renewal[key] = nil

    return false
end

local function warn_if_undersized(event_id: string, event: Event, servers: number)
    local needed = planner.shards(servers, #event.spec.options)
    if needed > event.spec.shards and not event.undersized then
        event.undersized = true
        warn(`[live] {event_id} has {event.spec.shards} shard(s) but {servers} servers need {needed}: raise its shards`)
    end
end

local function lead_group(event_id: string, event: Event, candidates_from: number, wanted: number, ttl: number)
    local group = aggregator.group_of(aggregator.shard_of(server_id, event.spec.shards), layout)
    local role = aggregator.group_role(group)
    if aggregator.candidate(server_id, role, candidates_from, wanted) and holds_lease(event_id, role, ttl) then
        local _, why =
            aggregator.group_pass(ports, event.spec, layout, group, event.group, now(), CONFIG.group_heartbeat)
        if why then
            trace("live", `{event_id} group {group} pass: {why}`)
        end
    else
        event.group = { previous = nil }
    end
end

local function run_root_pass(event_id: string, event: Event)
    local ok, snapshot, why = pcall(
        aggregator.root_pass,
        ports,
        event.spec,
        layout,
        event.root,
        now(),
        CONFIG.total_heartbeat,
        CONFIG.orphan_after,
        CONFIG.max_orphans
    )
    event.root_running = false
    if not ok then
        warn_once(`root:{event_id}`, `root pass failed for {event_id}: {snapshot}`)
        return
    end

    if why then
        trace("live", `{event_id} root pass: {why}`)
    end

    adopt(event, snapshot)
    if snapshot and now() - event.archived_at >= CONFIG.archive_interval then
        event.archived_at = now()
        task.spawn(archive_store.write, event_id, event.spec.kind, snapshot)
    end
end

local function lead_root(
    event_id: string,
    event: Event,
    at: number,
    candidates_from: number,
    wanted: number,
    ttl: number
)
    local role = aggregator.root_role()
    if aggregator.candidate(server_id, role, candidates_from, wanted) and holds_lease(event_id, role, ttl) then
        event.root_passed_at = at
        event.root_running = true
        task.spawn(run_root_pass, event_id, event)
    else
        event.root = { previous = nil, cursor = 0 }
    end
end

local function aggregate(event_id: string, event: Event)
    local at = now()
    local population = aggregator.population(event.snapshot)
    local ccu = math.max(1, population) * math.max(1, #players:GetPlayers())
    local per_group = math.min(event.spec.shards, layout.shards_per_group)
    local interval = planner.pass_interval(ccu, event_count, per_group)
    if at - event.group_passed_at < interval - CONFIG.aggregate_interval / 2 then
        return
    end

    event.group_passed_at = at
    warn_if_undersized(event_id, event, population)

    local stale_for = if event.snapshot then at - event.snapshot.at else 0
    local contenders = planner.max_contenders()
    local groups = aggregator.groups(event.spec, layout)
    local group_wanted = aggregator.widened(CONFIG.group_candidates, stale_for, CONFIG.widen_every, contenders)
    local group_ttl = planner.lease(interval)
    lead_group(event_id, event, population / groups, group_wanted, group_ttl)

    local root_every = math.max(interval, planner.root_interval(groups, per_group))
    if event.root_running or at - event.root_passed_at < root_every - CONFIG.aggregate_interval / 2 then
        return
    end

    local root_wanted = aggregator.widened(layout.candidates, stale_for, CONFIG.widen_every, contenders)
    lead_root(event_id, event, at, population, root_wanted, math.max(group_ttl, planner.lease(root_every)))
end

local function poll(event_id: string, event: Event)
    local at = now()
    local snapshot = event.snapshot
    local replicas = if snapshot then snapshot.replicas else 1
    local spacing = planner.poll_interval(aggregator.population(snapshot), replicas)
    if (snapshot == nil or at - snapshot.at > CONFIG.stale_after) and at - event.polled_at >= spacing then
        event.polled_at = at
        local ok, current = ports.totals.read(event_id, aggregator.replica_of(server_id, replicas))
        if ok then
            adopt(event, current)
        end
    end
end

local function push_progress(event_id: string, event: Event)
    if not event.changed then
        return
    end

    event.changed = false
    local display = live.display(event_id)
    if display then
        net.live.progress:fire_all(event_id, display.state, display.totals, aggregator.population(display))
    end
end

local function every(interval: number, jitter: number, step: () -> ...any)
    task.spawn(function()
        while running do
            task.wait(interval + math.random() * jitter)
            local ok, problem = pcall(step)
            if not ok then
                warn_once(tostring(step), `step failed: {problem}`)
            end
        end
    end)
end

local function subscribe(event: Event)
    task.spawn(function()
        while
            running
            and memory_store.subscribe(event.spec.id, function(snapshot)
                    adopt(event, snapshot)
                end)
                == nil
        do
            task.wait(CONFIG.subscribe_retry)
        end
    end)
end

local function new_event(definition: catalog.Definition): Event
    return {
        spec = {
            id = definition.id,
            kind = definition.kind,
            options = definition.options,
            goal = definition.goal,
            ends_at = definition.ends_at,
            shards = definition.shards,
        },
        reward_coins = definition.reward_coins,
        entry = counter.entry(),
        sent = counter.entry(),
        sent_at = 0,
        votes = {},
        snapshot = nil,
        archived = nil,
        archived_at = 0,
        shown_floor = {},
        changed = false,
        polled_at = 0,
        group = { previous = nil },
        group_passed_at = 0,
        root = { previous = nil, cursor = 0 },
        root_passed_at = 0,
        root_running = false,
        undersized = false,
    }
end

local function sync_player(player: Player)
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
end

local function flush_on_close()
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
end

local function start_loops()
    if backend_name == "http" then
        every(CONFIG.http_flush_interval, CONFIG.flush_jitter, function()
            flush(false)
        end)
    else
        every(CONFIG.flush_interval, CONFIG.flush_jitter, function()
            flush(false)
        end)
        every(CONFIG.aggregate_interval, 0, function()
            each_event("aggregate", aggregate)
        end)
        every(CONFIG.poll_interval, CONFIG.flush_jitter, function()
            each_event("poll", poll)
        end)
    end

    every(CONFIG.push_interval, 0, function()
        each_event("push", push_progress)
    end)
    every(CONFIG.reward_interval, 0, function()
        each_event("reward", grant_reward)
    end)
end

function live.start()
    if STUDIO and server_script_service:GetAttribute(DISABLED_ATTRIBUTE) == true then
        trace("live", "disabled by attribute")
        return
    end

    running = true
    backend_name = if STUDIO
        then server_script_service:GetAttribute(BACKEND_ATTRIBUTE) or CONFIG.backend
        else CONFIG.backend

    for _, definition in catalog do
        local event = new_event(definition)
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
            guard.limiter(CONFIG.vote_pace),
            { t.string(EVENT_ID_BYTES), t.string(OPTION_BYTES) },
            live.vote
        )
    )
    net.live.contribute:on(guard.decoy("live.contribute"))

    players.PlayerAdded:Connect(sync_player)
    players.PlayerRemoving:Connect(function(player)
        voting[player] = nil
    end)

    profiles.on_loaded(function(player)
        queue_unpublished(player)
        push_mine(player)
    end)

    start_loops()
    game:BindToClose(flush_on_close)
    trace("live", `started server {server_id} on {backend_name}`)
end

return live
