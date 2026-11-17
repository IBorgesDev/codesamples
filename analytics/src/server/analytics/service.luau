--!strict

local http_service = game:GetService("HttpService")
local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")
local run_service = game:GetService("RunService")
local server_script_service = game:GetService("ServerScriptService")
local server_storage = game:GetService("ServerStorage")

local breaker = require(script.Parent.Parent.net.breaker)
local buffer = require(script.Parent.buffer)
local http_budget = require(script.Parent.Parent.net.http_budget)
local server_id = require(script.Parent.Parent.net.identity)
local stats = require(script.Parent.Parent.dev.stats)
local trace = require(replicated_storage.Shared.util.trace)
local transport = require(script.Parent.transport)
local tuning = require(replicated_storage.Shared.config.tuning)
local validate = require(script.Parent.validate)

const CONFIG = tuning.analytics
const CONSUMER = "analytics"
const ECHO_ATTRIBUTE = "AnalyticsEcho"

local schema: validate.Schema = require(server_storage:WaitForChild("Schema").events) :: any

local analytics = {}

local queue = buffer.new(CONFIG.buffer_capacity)
local sessions: { [Player]: { id: string, started: number } } = {}
local random = Random.new()
local link = breaker.new(CONFIG.breaker_failures, CONFIG.breaker_cooldown)
local send: transport.Transport? = nil
local flushed_at = 0
local counts: { [string]: number } = { tracked = 0, sampled_out = 0, invalid = 0, sent = 0, discarded = 0 }

local function now(): number
    return DateTime.now().UnixTimestampMillis / 1000
end

local function report()
    for name, value in counts do
        stats(`analytics.{name}`, value)
    end

    stats("analytics.buffered", buffer.size(queue))
end

function analytics.track(name: string, player: Player?, props: { [string]: any }): boolean
    local definition = schema.events[name]
    local sample = if definition then definition.sample else nil
    if sample and random:NextNumber() >= sample then
        counts.sampled_out += 1
        return false
    end

    local session = if player then sessions[player] else nil
    local event: buffer.Event = {
        name = name,
        at = now(),
        user_id = if player then player.UserId else nil,
        session_id = if session then session.id else nil,
        weight = validate.weight(definition),
        props = props,
    }

    local ok, why = validate.event(schema, event)
    if not ok then
        counts.invalid += 1
        trace("analytics", `{name} rejected: {why}`)
        return false
    end

    buffer.push(queue, event)
    counts.tracked += 1

    return true
end

local function encode(batch: buffer.Batch): string
    return http_service:JSONEncode({
        schema = schema.version,
        server_id = server_id,
        place_id = game.PlaceId,
        place_version = game.PlaceVersion,
        batch_seq = batch.seq,
        sent_at = now(),
        dropped = batch.dropped,
        events = batch.events,
    })
end

local function backoff(batch: buffer.Batch, retry_after: number?): number
    if retry_after then
        return retry_after
    end

    return random:NextNumber() * math.min(CONFIG.backoff_cap, CONFIG.backoff_base * 2 ^ batch.attempts)
end

local function flush(at: number)
    local batch = buffer.take(queue, schema.limits.batch_events, at)
    if batch == nil then
        return
    end

    flushed_at = at
    if buffer.expired(queue, at, CONFIG.max_retry_seconds) then
        counts.discarded += #batch.events
        trace("analytics", `batch {batch.seq} gave up after {batch.attempts} attempts, past the dedupe window`)
        buffer.acked(queue)
        return
    end

    local deliver = send
    if deliver == nil then
        counts.discarded += #batch.events
        buffer.acked(queue)
        return
    end

    if not link:allow() or not http_budget.take(CONSUMER) then
        buffer.failed(queue, at, backoff(batch, nil))
        return
    end

    local result, retry_after = deliver(encode(batch), #batch.events)
    if result == "retry" then
        link:failure()
        buffer.failed(queue, at, backoff(batch, retry_after))
        return
    end

    link:success()
    if result == "ok" then
        counts.sent += #batch.events
    else
        counts.discarded += #batch.events
        trace("analytics", `batch {batch.seq} refused by the service, {#batch.events} events dropped`)
    end

    buffer.acked(queue)
end

local function step()
    local at = now()
    if not buffer.ready(queue, at) then
        return
    end

    local full = buffer.size(queue) >= schema.limits.batch_events
    if full or queue.pending ~= nil or at - flushed_at >= CONFIG.flush_interval then
        flush(at)
    end

    report()
end

local function connect()
    if run_service:IsStudio() and server_script_service:GetAttribute(ECHO_ATTRIBUTE) == true then
        send = transport.echo(function(line)
            trace("analytics", line)
        end)
        return
    end

    send = transport.http(CONFIG.url_secret, CONFIG.token_secret)
    if send == nil then
        trace("analytics", "no analytics_url or analytics_token secret, events are counted and discarded")
    end
end

function analytics.start()
    connect()

    local function open_session(player: Player)
        sessions[player] = { id = http_service:GenerateGUID(false), started = now() }
        analytics.track("session_start", player, { teleported = player:GetJoinData().SourcePlaceId ~= nil })
    end

    players.PlayerAdded:Connect(open_session)
    for _, player in players:GetPlayers() do
        open_session(player)
    end

    players.PlayerRemoving:Connect(function(player)
        local session = sessions[player]
        if session then
            analytics.track("session_end", player, { seconds = now() - session.started })
            sessions[player] = nil
        end
    end)

    task.spawn(function()
        while true do
            task.wait(CONFIG.check_interval)
            local ok, problem = pcall(function()
                step()
            end)

            if not ok then
                trace("analytics", `flush failed: {problem}`)
            end
        end
    end)

    game:BindToClose(function()
        local deadline = os.clock() + CONFIG.shutdown_flush_timeout
        while (buffer.size(queue) > 0 or queue.pending ~= nil) and os.clock() < deadline do
            queue.retry_at = 0
            flush(now())
            task.wait()
        end
    end)
end

return analytics
