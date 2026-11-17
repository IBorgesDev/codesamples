--!strict

local http_service = game:GetService("HttpService")
local players = game:GetService("Players")
local run_service = game:GetService("RunService")
local server_script_service = game:GetService("ServerScriptService")
local server_storage = game:GetService("ServerStorage")

local breaker = require(script.Parent.Parent.net.breaker)
local http_budget = require(script.Parent.Parent.net.http_budget)
local outbox = require(script.Parent.outbox)
local server_id = require(script.Parent.Parent.net.identity)
local stats = require(script.Parent.Parent.dev.stats)
local trace = require(script.Parent.Parent.util.trace)
local transport = require(script.Parent.transport)
local tuning = require(script.Parent.Parent.config.tuning)
local validate = require(script.Parent.validate)

const CONFIG = tuning.analytics
const CONSUMER = "analytics"
const ECHO_ATTRIBUTE = "AnalyticsEcho"

local schema: validate.Schema = require(server_storage:WaitForChild("Schema").events) :: any

local analytics = {}

local queue = outbox.new(CONFIG.buffer_capacity)
local sessions: { [Player]: { id: string, started: number } } = {}
local random = Random.new()
local link = breaker.new(CONFIG.breaker_failures, CONFIG.breaker_cooldown)
local send: transport.Transport? = nil
local sending = false
local flushed_at = 0
local counts: { [string]: number } = { tracked = 0, sampled_out = 0, invalid = 0, sent = 0, discarded = 0 }

local function now(): number
    return DateTime.now().UnixTimestampMillis / 1000
end

local function report()
    for name, value in counts do
        stats(`analytics.{name}`, value)
    end

    stats("analytics.buffered", outbox.size(queue))
end

function analytics.track(name: string, player: Player?, props: { [string]: any }): boolean
    local sample = validate.sample(schema.events[name])
    if sample and random:NextNumber() >= sample then
        counts.sampled_out += 1
        return false
    end

    local session = if player then sessions[player] else nil
    local event: outbox.Event = {
        name = name,
        at = now(),
        user_id = if player then player.UserId else nil,
        session_id = if session then session.id else nil,
        weight = if sample then 1 / sample else 1,
        props = props,
    }

    local ok, why = validate.event(schema, event)
    if not ok then
        counts.invalid += 1
        trace("analytics", `{name} rejected: {why}`)
        return false
    end

    event.props = table.clone(props)
    outbox.push(queue, event)
    counts.tracked += 1

    return true
end

local function encode(batch: outbox.Batch): string
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

local function backoff(batch: outbox.Batch, retry_after: number?): number
    if retry_after then
        return math.min(retry_after, CONFIG.backoff_cap)
    end

    return random:NextNumber() * math.min(CONFIG.backoff_cap, CONFIG.backoff_base * 2 ^ batch.attempts)
end

local function discard(batch: outbox.Batch, why: string)
    counts.discarded += #batch.events
    trace("analytics", `batch {batch.seq} dropped with {#batch.events} events: {why}`)
    outbox.settle(queue, batch)
end

local function flush(at: number)
    if sending then
        return
    end

    local batch = outbox.take(queue, schema.limits.batch_events, at)
    if batch == nil then
        return
    end

    flushed_at = at

    local deliver = send
    if deliver == nil then
        counts.discarded += #batch.events
        outbox.settle(queue, batch)
        return
    end

    if outbox.expired(batch, at, CONFIG.max_retry_seconds) then
        discard(batch, `gave up after {batch.attempts} attempts, past the dedupe window`)
        return
    end

    local encoded, body = pcall(encode, batch)
    if not encoded then
        discard(batch, "could not be encoded")
        return
    end

    if not link:allow() or not http_budget.take(CONSUMER) then
        outbox.retry_in(queue, batch, at, backoff(batch, nil))
        return
    end

    sending = true
    local delivered, result, retry_after = pcall(deliver, body, #batch.events)
    sending = false

    if not delivered or result == "retry" then
        link:failure()
        outbox.retry_in(queue, batch, at, backoff(batch, if delivered then retry_after else nil))
        return
    end

    link:success()
    if result == "ok" then
        counts.sent += #batch.events
        outbox.settle(queue, batch)
    else
        discard(batch, "refused by the service")
    end
end

local function due(at: number): boolean
    if not outbox.ready(queue, at) then
        return false
    end

    local full = outbox.size(queue) >= schema.limits.batch_events

    return full or outbox.retrying(queue) or at - flushed_at >= CONFIG.flush_interval
end

local function step()
    local at = now()
    if due(at) then
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

local function open_session(player: Player)
    sessions[player] = { id = http_service:GenerateGUID(false), started = now() }
    analytics.track("session_start", player, { teleported = player:GetJoinData().SourcePlaceId ~= nil })
end

local function close_session(player: Player)
    local session = sessions[player]
    if session then
        analytics.track("session_end", player, { seconds = now() - session.started })
        sessions[player] = nil
    end
end

local function flush_on_close()
    local deadline = os.clock() + CONFIG.shutdown_flush_timeout
    while not outbox.empty(queue) and os.clock() < deadline do
        outbox.retry_now(queue)
        flush(now())
        task.wait()
    end
end

function analytics.start()
    connect()

    players.PlayerAdded:Connect(open_session)
    players.PlayerRemoving:Connect(close_session)
    for _, player in players:GetPlayers() do
        open_session(player)
    end

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

    game:BindToClose(flush_on_close)
end

return analytics
