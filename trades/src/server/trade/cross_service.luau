--!strict

local http_service = game:GetService("HttpService")
local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")

local coordinator = require(script.Parent.coordinator)
local cross = require(script.Parent.cross)
local guard = require(script.Parent.Parent.net.guard)
local negotiation = require(script.Parent.negotiation)
local net = require(replicated_storage.Shared.net)
local profiles = require(script.Parent.Parent.data.profiles)
local records = require(script.Parent.records)
local server_id = require(script.Parent.Parent.net.identity)
local stats = require(script.Parent.Parent.dev.stats)
local trace = require(replicated_storage.Shared.util.trace)
local tuning = require(replicated_storage.Shared.config.tuning)
local types = require(script.Parent.types)
local view = require(script.Parent.view)

const CONFIG = tuning.trade

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
    tx_id: string?,
    started: number?,
    busy: boolean,
    due: number,
    closes_at: number?,
}

export type Context = {
    ports: types.Ports,
    coord: coordinator.Coordinator,
    busy: (Player) -> boolean,
    emit: (kind: string, tx_id: string?, reason: string?, seconds: number, player: Player) -> (),
}

local cross_service = {}

local entries: { [Player]: Entry } = {}
local by_session: { [string]: Entry } = {}
local outgoing: { [Player]: { to: number, at: number } } = {}
local invites: { [Player]: { [number]: { server: string, at: number } } } = {}
local joining: { [Player]: boolean } = {}
local last_answer: { [Player]: number } = {}
local limiter = guard.limiter(CONFIG.cross_pace)
local context: Context

local function wall_now(): number
    return DateTime.now().UnixTimestampMillis / 1000
end

local function push(entry: Entry)
    local shared = entry.shared
    if shared and entry.player.Parent == players then
        net.trade.view:set(
            entry.player,
            view.of(entry.id, entry.status, entry.reason, shared.session, entry.player.UserId, wall_now())
        )
    end
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
    entry.closes_at = os.clock() + CONFIG.close_after
    push(entry)
    hint(entry)

    local started = entry.started
    if started then
        local seconds = os.clock() - started
        context.emit(status, entry.tx_id, reason, seconds, entry.player)
        stats("trade.cross_last_seconds", math.round(seconds * 1000) / 1000)
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
        tx_id = nil,
        started = nil,
        busy = false,
        due = 0,
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

local function terminal(result: string?): boolean
    return result ~= nil and result ~= "open" and result ~= "pending" and result ~= "waiting"
end

local function lock(entry: Entry, account: types.Account)
    if records.budget() < CONFIG.min_update_budget then
        return
    end

    local tx_id = http_service:GenerateGUID(false)
    entry.status = "locking"
    entry.started = os.clock()
    push(entry)

    local result, why = cross.commit(context.coord, context.ports, entry.id, account, tx_id, wall_now())
    if result == "waiting" then
        entry.status = "negotiating"
        entry.started = nil
        return
    end

    entry.tx_id = tx_id
    hint(entry)
    if terminal(result) then
        close(entry, view.status_of(result), why)
    end
end

local function drive_a(entry: Entry, shared: Shared, account: types.Account)
    if shared.outcome ~= nil then
        cross.resume(context.coord, context.ports, shared, account)
        close(entry, view.status_of(shared.outcome), shared.reason)
        return
    end

    if shared.tx_id == nil then
        local lock_at = shared.session.lock_at
        if lock_at and wall_now() >= lock_at then
            lock(entry, account)
        end

        return
    end

    entry.status = "locking"
    local locked_for = wall_now() - (shared.locked_at or 0)
    if not shared.opened or locked_for >= CONFIG.record_timeout then
        local result = cross.resume(context.coord, context.ports, shared, account)
        if terminal(result) then
            close(entry, view.status_of(result :: string), nil)
        end
    end
end

local function drive_b(entry: Entry, shared: Shared, account: types.Account)
    local tx_id = shared.tx_id
    if tx_id == nil then
        return
    end

    entry.status = "locking"
    entry.tx_id = tx_id
    entry.started = entry.started or os.clock()

    if shared.outcome ~= nil then
        cross.resume(context.coord, context.ports, shared, account)
        close(entry, view.status_of(shared.outcome), shared.reason)
        return
    end

    if records.budget() < CONFIG.min_update_budget then
        return
    end

    local result: string? = nil
    if account.data.escrow[tx_id] then
        result = cross.resume(context.coord, context.ports, shared, account)
    elseif shared.opened then
        result = cross.prepare(context.coord, context.ports, shared, account)
    elseif wall_now() - (shared.locked_at or 0) >= CONFIG.persist_timeout + CONFIG.lock_grace then
        result = cross.abandon(context.coord, context.ports, shared, "a_silent")
    end

    if terminal(result) then
        close(entry, view.status_of(result :: string), nil)
    end
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

    if entry.role == "a" then
        drive_a(entry, current, loaded.account)
    else
        drive_b(entry, current, loaded.account)
    end

    if entry.closes_at == nil then
        push(entry)
        local lock_at = current.session.lock_at
        if entry.role == "a" and current.tx_id == nil and lock_at then
            entry.due = math.min(entry.due, os.clock() + math.max(0, lock_at - wall_now()))
        end
    end
end

local function step(entry: Entry)
    entry.due = os.clock() + CONFIG.remote_poll_interval
    local ok, problem = pcall(function()
        drive(entry)
    end)

    if not ok then
        trace("trade", `cross {entry.id} step failed: {problem}`)
    end

    entry.busy = false
end

local function tick()
    local now = os.clock()
    for _, entry in entries do
        if entry.closes_at then
            if now >= entry.closes_at then
                remove(entry)
            end
        elseif not entry.busy and now >= entry.due then
            entry.busy = true
            task.spawn(step, entry)
        end
    end
end

local function pending_invites(target: Player, now: number): { [number]: { server: string, at: number } }
    local list = invites[target]
    if list == nil then
        list = {}
        invites[target] = list
    end

    for from, invite in list do
        if now - invite.at > CONFIG.invite_timeout then
            list[from] = nil
        end
    end

    return list
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

    local now = os.clock()
    local list = pending_invites(target, now)
    local count = 0
    for _ in list do
        count += 1
    end

    if list[from] or count >= CONFIG.max_invites then
        return
    end

    list[from] = { server = server, at = now }
    net.trade.invited:fire(target, from)
end

local function on_accepted(message: coordinator.Message)
    local session_id, from, to, server = message.session, message.from, message.to, message.server
    if type(session_id) ~= "string" or type(from) ~= "number" or type(to) ~= "number" or type(server) ~= "string" then
        return
    end

    local inviter = players:GetPlayerByUserId(to)
    local pending = if inviter then outgoing[inviter] else nil
    if
        inviter
        and pending
        and pending.to == from
        and os.clock() - pending.at <= CONFIG.invite_timeout
        and not context.busy(inviter)
        and entries[inviter] == nil
        and profiles.get(inviter) ~= nil
    then
        outgoing[inviter] = nil
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
            entry.due = 0
        end
    end
end

function cross_service.busy(player: Player): boolean
    return entries[player] ~= nil or joining[player] == true
end

function cross_service.invite(player: Player, target_id: number): boolean
    outgoing[player] = { to = target_id, at = os.clock() }
    task.spawn(function()
        local ok, server = context.coord.presence_get(target_id)
        if ok and server ~= nil and server ~= server_id then
            context.coord.send(server, { kind = "invite", from = player.UserId, to = target_id, server = server_id })
        end
    end)

    return true
end

function cross_service.answer(player: Player, from_id: number, accept: boolean): boolean?
    local list = invites[player]
    local invite = if list then list[from_id] else nil
    if list == nil or invite == nil then
        return nil
    end

    list[from_id] = nil
    local now = os.clock()
    if
        not accept
        or now - invite.at > CONFIG.invite_timeout
        or now - (last_answer[player] or -math.huge) < CONFIG.cross_answer_cooldown
        or context.busy(player)
        or cross_service.busy(player)
        or profiles.get(player) == nil
    then
        return false
    end

    last_answer[player] = now
    local session_id = http_service:GenerateGUID(false)
    local shared = cross.new(session_id, from_id, player.UserId, invite.server, server_id)
    joining[player] = true
    local created = context.coord.create(shared)
    joining[player] = nil
    if not created then
        return false
    end

    if player.Parent ~= players or profiles.get(player) == nil then
        local user_id = player.UserId
        task.spawn(function()
            cross.apply(context.coord, session_id, user_id, { kind = "cancel" }, wall_now())
        end)
        return false
    end

    add(player, session_id, "b", invite.server, shared)
    context.coord.send(
        invite.server,
        { kind = "accepted", session = session_id, from = player.UserId, to = from_id, server = server_id }
    )

    return true
end

function cross_service.apply(player: Player, op: negotiation.Op): boolean?
    local entry = entries[player]
    if entry == nil then
        return nil
    end

    if entry.status ~= "negotiating" or entry.closes_at then
        return false
    end

    if op.kind ~= "cancel" and not limiter:take(player) then
        return false
    end

    local ok, shared = cross.apply(context.coord, entry.id, player.UserId, op, wall_now())
    if ok and shared then
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

    players.PlayerRemoving:Connect(function(player)
        invites[player] = nil
        outgoing[player] = nil
        joining[player] = nil
        last_answer[player] = nil
        local entry = entries[player]
        if entry then
            remove(entry)
            if entry.status == "negotiating" and entry.closes_at == nil then
                task.spawn(function()
                    cross.apply(context.coord, entry.id, player.UserId, { kind = "cancel" }, wall_now())
                    hint(entry)
                end)
            end
        end

        task.spawn(context.coord.presence_clear, player.UserId, server_id)
    end)

    task.spawn(subscribe)

    task.spawn(function()
        while true do
            task.wait(CONFIG.tick_interval)
            tick()
        end
    end)

    task.spawn(function()
        while true do
            task.wait(CONFIG.presence_refresh)
            refresh_presence()
        end
    end)
end

return cross_service
