--!strict

local http_service = game:GetService("HttpService")
local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")

local coordinator = require(script.Parent.coordinator)
local cross = require(script.Parent.cross)
local every = require(script.Parent.Parent.util.every)
local guard = require(script.Parent.Parent.net.guard)
local invites = require(script.Parent.invites)
local negotiation = require(script.Parent.negotiation)
local net = require(replicated_storage.Shared.net)
local profiles = require(script.Parent.Parent.data.profiles)
local protocol = require(script.Parent.protocol)
local records = require(script.Parent.records)
local server_id = require(script.Parent.Parent.net.identity)
local stat = require(script.Parent.Parent.dev.stats)
local trace = require(script.Parent.Parent.util.trace)
local tuning = require(script.Parent.Parent.config.tuning)
local types = require(script.Parent.types)
local view = require(script.Parent.view)

const TRADE = tuning.trade
const CONFIG = tuning.cross

type Shared = coordinator.Shared
type Status = view.Status

type Entry = {
    id: string,
    player: Player,
    role: types.Role,
    peer_server: string,
    shared: Shared?,
    status: Status,
    reason: string?,
    shown_version: number,
    shown_at: number,
    lock_paid: boolean,
    started: number?,
    stepping: boolean,
    cancelling: boolean,
    next_step_at: number,
    closes_at: number?,
}

export type Context = {
    ports: types.Ports,
    coord: coordinator.Coordinator,
    busy: (Player) -> boolean,
    lock_limiter: guard.Limiter,
}

local cross_service = {}

local entries: { [Player]: Entry } = {}
local by_session: { [string]: Entry } = {}
local sent_invites: { [Player]: { to: number, at: number } } = {}
local received_invites: invites.Book<string> = invites.book(TRADE.max_invites, TRADE.invite_timeout)
local joining: { [Player]: boolean } = {}
local last_answer: { [Player]: number } = {}
local limiter = guard.limiter(CONFIG.pace)
local context: Context

local function wall_now(): number
    return DateTime.now().UnixTimestampMillis / 1000
end

local function push(entry: Entry)
    local shared = entry.shared
    if shared == nil or entry.player.Parent ~= players then
        return
    end

    if shared.session.version ~= entry.shown_version then
        entry.shown_version = shared.session.version
        entry.shown_at = os.clock()
    end

    net.trade.view:set(
        entry.player,
        view.of(
            entry.id,
            entry.status,
            entry.reason,
            shared.session,
            entry.player.UserId,
            wall_now(),
            os.clock() - entry.shown_at
        )
    )
end

local function hint(entry: Entry)
    task.spawn(context.coord.send, entry.peer_server, { kind = "changed", session = entry.id })
end

local function observe(entry: Entry, shared: Shared)
    local current = entry.shared
    if current == nil or shared.rev >= current.rev then
        entry.shared = shared
    end
end

local function close(entry: Entry, status: Status, reason: string?)
    if entry.closes_at then
        return
    end

    entry.status = status
    entry.reason = reason
    entry.closes_at = os.clock() + TRADE.close_after
    push(entry)
    hint(entry)

    local started = entry.started
    if started then
        stat("trade.cross_last_seconds", math.round((os.clock() - started) * 1000) / 1000)
    end

    trace("trade", `cross {entry.id} {entry.role} {status} {reason or ""}`)
end

local function add(player: Player, session_id: string, role: types.Role, peer_server: string, shared: Shared?): Entry
    local entry: Entry = {
        id = session_id,
        player = player,
        role = role,
        peer_server = peer_server,
        shared = shared,
        status = "negotiating",
        reason = nil,
        shown_version = 0,
        shown_at = -math.huge,
        lock_paid = false,
        started = nil,
        stepping = false,
        cancelling = false,
        next_step_at = 0,
        closes_at = nil,
    }
    entries[player] = entry
    by_session[session_id] = entry
    push(entry)

    return entry
end

local function remove(entry: Entry)
    if entries[entry.player] == entry then
        entries[entry.player] = nil
    end

    if by_session[entry.id] == entry then
        by_session[entry.id] = nil
    end
end

local function has_budget(): boolean
    return records.budget() >= TRADE.min_update_budget
end

local function pays_for_lock(entry: Entry): boolean
    if not entry.lock_paid then
        entry.lock_paid = context.lock_limiter:take(entry.player)
    end

    return entry.lock_paid
end

local function lock(entry: Entry, account: types.Account): (string?, string?)
    if not (has_budget() and pays_for_lock(entry)) then
        return nil, nil
    end

    entry.status = "locking"
    entry.started = os.clock()
    push(entry)

    local tx_id = http_service:GenerateGUID(false)
    local result, why = cross.commit(context.coord, context.ports, entry.id, account, tx_id, wall_now())
    if result == "waiting" then
        entry.status = "negotiating"
        entry.started = nil
        return nil, nil
    end

    hint(entry)

    return result, why
end

local function drive_a(entry: Entry, shared: Shared, account: types.Account): (string?, string?)
    if shared.tx_id == nil then
        local lock_at = shared.session.lock_at
        if lock_at and wall_now() >= lock_at then
            return lock(entry, account)
        end

        return nil, nil
    end

    entry.status = "locking"
    local locked_for = wall_now() - (shared.locked_at or 0)
    if not shared.opened or locked_for >= TRADE.record_timeout then
        return cross.resume(context.coord, context.ports, shared, account), nil
    end

    return nil, nil
end

local function drive_b(entry: Entry, shared: Shared, account: types.Account): string?
    local tx_id = shared.tx_id
    if tx_id == nil then
        return nil
    end

    entry.status = "locking"
    entry.started = entry.started or os.clock()
    if not has_budget() then
        return nil
    end

    if account.data.escrow[tx_id] then
        return cross.resume(context.coord, context.ports, shared, account)
    end

    if shared.opened then
        return if pays_for_lock(entry) then cross.prepare(context.coord, context.ports, shared, account) else nil
    end

    if wall_now() - (shared.locked_at or 0) >= TRADE.persist_timeout + CONFIG.lock_grace then
        return cross.abandon(context.coord, context.ports, shared, "a_silent")
    end

    return nil
end

local function drive(entry: Entry)
    local ok, shared = context.coord.get(entry.id)
    if not ok then
        return
    end

    if shared == nil then
        close(entry, if entry.status == "negotiating" then "aborted" else "pending", "expired")
        return
    end

    observe(entry, shared)
    local current = entry.shared :: Shared
    if current.session.state == "cancelled" then
        close(entry, "aborted", "cancelled")
        return
    end

    local loaded = profiles.get(entry.player)
    if loaded == nil then
        return
    end

    if current.outcome ~= nil then
        cross.resume(context.coord, context.ports, current, loaded.account)
        close(entry, view.status_of(current.outcome), current.reason)
        return
    end

    local result: string?, why: string? = nil, nil
    if entry.role == "a" then
        result, why = drive_a(entry, current, loaded.account)
    else
        result = drive_b(entry, current, loaded.account)
    end

    if protocol.decided(result) then
        close(entry, view.status_of(result :: string), why)
        return
    end

    push(entry)
    local lock_at = current.session.lock_at
    if entry.role == "a" and current.tx_id == nil and lock_at then
        entry.next_step_at = math.min(entry.next_step_at, os.clock() + math.max(0, lock_at - wall_now()))
    end
end

local function step(entry: Entry)
    entry.next_step_at = os.clock() + CONFIG.remote_poll_interval
    local ok, problem = pcall(function()
        drive(entry)
    end)
    if not ok then
        trace("trade", `cross {entry.id} step failed: {problem}`)
    end

    entry.stepping = false
end

local function tick()
    local now = os.clock()
    for _, entry in entries do
        if entry.closes_at then
            if now >= entry.closes_at then
                remove(entry)
            end
        elseif not entry.stepping and now >= entry.next_step_at then
            entry.stepping = true
            task.spawn(step, entry)
        end
    end
end

local function on_invite(message: coordinator.Message)
    local from, to, server = message.from, message.to, message.server
    if type(from) ~= "number" or type(to) ~= "number" or type(server) ~= "string" then
        return
    end

    local target = players:GetPlayerByUserId(to)
    if target == nil or cross_service.busy(target) or context.busy(target) or profiles.get(target) == nil then
        return
    end

    if received_invites.offer(target, from, server, os.clock()) then
        net.trade.invited:fire(target, from)
    end
end

local function on_accepted(message: coordinator.Message)
    local session_id, from, to, server = message.session, message.from, message.to, message.server
    if type(session_id) ~= "string" or type(from) ~= "number" or type(to) ~= "number" or type(server) ~= "string" then
        return
    end

    local inviter = players:GetPlayerByUserId(to)
    local sent = if inviter then sent_invites[inviter] else nil
    if
        inviter
        and sent
        and sent.to == from
        and os.clock() - sent.at <= TRADE.invite_timeout
        and not context.busy(inviter)
        and not cross_service.busy(inviter)
        and profiles.get(inviter) ~= nil
    then
        sent_invites[inviter] = nil
        add(inviter, session_id, "a", server, nil)
        return
    end

    cross.apply(context.coord, session_id, to, { kind = "cancel" }, wall_now())
    context.coord.send(server, { kind = "changed", session = session_id })
end

local function on_message(message: coordinator.Message)
    if message.kind == "invite" then
        on_invite(message)
    elseif message.kind == "accepted" then
        on_accepted(message)
    elseif message.kind == "changed" and type(message.session) == "string" then
        local entry = by_session[message.session]
        if entry then
            entry.next_step_at = 0
        end
    end
end

local function cancel_remote(session_id: string, user_id: number)
    cross.apply(context.coord, session_id, user_id, { kind = "cancel" }, wall_now())
end

function cross_service.busy(player: Player): boolean
    return entries[player] ~= nil or joining[player] == true
end

function cross_service.invite(player: Player, target_id: number): boolean
    sent_invites[player] = { to = target_id, at = os.clock() }
    task.spawn(function()
        local ok, server = context.coord.presence_get(target_id)
        if ok and server ~= nil and server ~= server_id then
            context.coord.send(server, { kind = "invite", from = player.UserId, to = target_id, server = server_id })
        end
    end)

    return true
end

function cross_service.invited(player: Player, from_id: number): boolean
    return received_invites.peek(player, from_id, os.clock())
end

function cross_service.answer(player: Player, from_id: number, accept: boolean): boolean
    local now = os.clock()
    local inviter_server = received_invites.take(player, from_id, now)
    if
        inviter_server == nil
        or not accept
        or now - (last_answer[player] or -math.huge) < CONFIG.answer_cooldown
        or context.busy(player)
        or cross_service.busy(player)
        or profiles.get(player) == nil
    then
        return false
    end

    last_answer[player] = now
    local session_id = http_service:GenerateGUID(false)
    local user_id = player.UserId
    local shared = cross.new(session_id, from_id, user_id, inviter_server, server_id)
    joining[player] = true
    local created = context.coord.create(shared)
    joining[player] = nil
    if not created then
        return false
    end

    if player.Parent ~= players or profiles.get(player) == nil or context.busy(player) or entries[player] then
        task.spawn(cancel_remote, session_id, user_id)
        return false
    end

    add(player, session_id, "b", inviter_server, shared)
    context.coord.send(
        inviter_server,
        { kind = "accepted", session = session_id, from = user_id, to = from_id, server = server_id }
    )

    return true
end

local function may_apply(entry: Entry, op: negotiation.Op): boolean
    if entry.status ~= "negotiating" or entry.closes_at or entry.cancelling then
        return false
    end

    if op.kind == "cancel" then
        return true
    end

    if op.kind == "accept" and os.clock() - entry.shown_at < TRADE.accept_delay then
        return false
    end

    return limiter:take(entry.player)
end

function cross_service.apply(player: Player, op: negotiation.Op): boolean
    local entry = entries[player]
    if entry == nil or not may_apply(entry, op) then
        return false
    end

    entry.cancelling = op.kind == "cancel"
    local ok, shared = cross.apply(context.coord, entry.id, player.UserId, op, wall_now())
    entry.cancelling = false
    if ok and shared then
        if op.kind ~= "accept" and op.kind ~= "cancel" then
            entry.shown_version = shared.session.version
            entry.shown_at = -math.huge
        end

        observe(entry, shared)
        hint(entry)
        if shared.session.state == "cancelled" then
            close(entry, "aborted", "cancelled")
        else
            push(entry)
        end
    end

    return ok
end

local function leave(player: Player)
    received_invites.forget(player)
    sent_invites[player] = nil
    joining[player] = nil
    last_answer[player] = nil
    local entry = entries[player]
    if entry then
        remove(entry)
        local shared = entry.shared
        if entry.status == "negotiating" and entry.closes_at == nil then
            task.spawn(function()
                cancel_remote(entry.id, player.UserId)
                hint(entry)
            end)
        elseif entry.status == "locking" and shared and entry.closes_at == nil then
            task.spawn(function()
                cross.abandon(context.coord, context.ports, shared, `{entry.role}_left`)
                hint(entry)
            end)
        end
    end

    task.spawn(context.coord.presence_clear, player.UserId, server_id)
end

local function subscribe()
    while coordinator.subscribe(server_id, on_message) == nil do
        task.wait(CONFIG.subscribe_retry)
    end
end

local function refresh_presence()
    for _, player in players:GetPlayers() do
        if profiles.get(player) then
            task.spawn(context.coord.presence_set, player.UserId, server_id)
        end
    end
end

function cross_service.start(new_context: Context)
    context = new_context

    profiles.on_loaded(function(player)
        context.coord.presence_set(player.UserId, server_id)
    end)

    players.PlayerRemoving:Connect(leave)
    task.spawn(subscribe)
    every("cross trade tick", TRADE.tick_interval, tick)
    every("presence refresh", CONFIG.presence_refresh, refresh_presence)
end

return cross_service
