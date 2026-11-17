--!strict

local http_service = game:GetService("HttpService")
local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")
local run_service = game:GetService("RunService")

local coordinator = require(script.Parent.coordinator)
local cross_service = require(script.Parent.cross_service)
local gift_service = require(script.Parent.gift_service)
local guard = require(script.Parent.Parent.net.guard)
local inventory = require(script.Parent.inventory)
local negotiation = require(script.Parent.negotiation)
local net = require(replicated_storage.Shared.net)
local profiles = require(script.Parent.Parent.data.profiles)
local protocol = require(script.Parent.protocol)
local records = require(script.Parent.records)
local stats = require(script.Parent.Parent.dev.stats)
local trace = require(replicated_storage.Shared.util.trace)
local tuning = require(replicated_storage.Shared.config.tuning)
local types = require(script.Parent.types)
local view = require(script.Parent.view)

const CONFIG = tuning.trade
const MAX_USER_ID = 2 ^ 53
const MAX_VERSION = 2 ^ 31

type Status = view.Status

type Trade = {
    id: string,
    session: negotiation.Session,
    a: Player,
    b: Player,
    status: Status,
    reason: string?,
    closes_at: number?,
}

export type Event = {
    kind: string,
    tx_id: string?,
    reason: string?,
    seconds: number,
    players: { Player },
    cross: boolean,
}

local trade = {}

local active: { [Player]: Trade } = {}
local invites: { [Player]: { [number]: { from: Player, at: number } } } = {}
local last_invite: { [Player]: number } = {}
local listeners: { (Event) -> () } = {}

local store_name = if run_service:IsStudio()
    then CONFIG.store_name .. tuning.profiles.studio_suffix
    else CONFIG.store_name
local record_store = records.open(store_name)

local ports: types.Ports = {
    records = record_store,
    now = function()
        return os.time()
    end,
    later = function(work)
        task.spawn(work)
    end,
}

function trade.ports(): types.Ports
    return ports
end

function trade.on_event(listener: (Event) -> ())
    table.insert(listeners, listener)
end

local function emit(event: Event)
    for _, listener in listeners do
        task.spawn(listener, event)
    end
end

local function push(entry: Trade)
    for _, player in { entry.a, entry.b } do
        if player.Parent == players then
            net.trade.view:set(
                player,
                view.of(entry.id, entry.status, entry.reason, entry.session, player.UserId, os.clock())
            )
        end
    end
end

local function busy(player: Player): boolean
    return active[player] ~= nil or cross_service.busy(player)
end

local function finish(entry: Trade, status: Status, reason: string?)
    entry.status = status
    entry.reason = reason
    entry.closes_at = os.clock() + CONFIG.close_after
    push(entry)
end

local function side(player: Player, party: negotiation.Party): types.Side
    return { user_id = player.UserId, coins = party.coins, items = party.items, ready = false }
end

local function execute(entry: Trade)
    entry.status = "locking"
    push(entry)

    local a, b = profiles.get(entry.a), profiles.get(entry.b)
    if a == nil or b == nil then
        finish(entry, "aborted", "left")
        return
    end

    if records.budget() < CONFIG.min_update_budget then
        finish(entry, "aborted", "busy")
        return
    end

    local tx_id = http_service:GenerateGUID(false)
    local started = os.clock()
    local opened, why = protocol.open(
        ports,
        a.account,
        tx_id,
        side(entry.a, entry.session.a),
        side(entry.b, entry.session.b),
        entry.session.version
    )

    local outcome: string = opened
    if opened == "open" then
        local prepared, prepared_why = protocol.prepare(ports, b.account, tx_id)
        outcome = prepared
        why = prepared_why
        if prepared == "committed" or prepared == "aborted" or prepared == "refused" then
            protocol.finalize(ports, a.account, tx_id)
        end
    end

    local seconds = os.clock() - started
    emit({
        kind = outcome,
        tx_id = tx_id,
        reason = why,
        seconds = seconds,
        players = { entry.a, entry.b },
        cross = false,
    })
    stats("trade.last_seconds", math.round(seconds * 1000) / 1000)
    trace("trade", `{tx_id} {outcome} {why or ""} in {math.round(seconds * 1000)} ms`)

    if outcome == "committed" then
        finish(entry, "committed", nil)
    elseif outcome == "aborted" or outcome == "refused" then
        finish(entry, "aborted", why)
    else
        finish(entry, "pending", why)
    end
end

local function negotiating(player: Player): Trade?
    local entry = active[player]
    if entry and entry.status == "negotiating" then
        return entry
    end

    return nil
end

local function apply(player: Player, op: negotiation.Op): boolean
    local remote = cross_service.apply(player, op)
    if remote ~= nil then
        return remote
    end

    local entry = negotiating(player)
    if entry == nil then
        return false
    end

    local ok = negotiation.apply(entry.session, player.UserId, op, os.clock())
    if ok then
        if entry.session.state == "cancelled" then
            finish(entry, "aborted", "cancelled")
        else
            push(entry)
        end
    end

    return ok
end

function trade.invite(player: Player, target_id: number): boolean
    local now = os.clock()
    if
        busy(player)
        or not profiles.get(player)
        or now - (last_invite[player] or -math.huge) < CONFIG.invite_cooldown
    then
        return false
    end

    if target_id == player.UserId then
        return false
    end

    last_invite[player] = now
    local target = players:GetPlayerByUserId(target_id)
    if target == nil then
        return cross_service.invite(player, target_id)
    end

    if busy(target) or not profiles.get(target) then
        return false
    end

    local list = invites[target]
    if list == nil then
        list = {}
        invites[target] = list
    end

    local count = 0
    for from_id, invite in list do
        if now - invite.at > CONFIG.invite_timeout or invite.from.Parent ~= players then
            list[from_id] = nil
        else
            count += 1
        end
    end

    if list[player.UserId] or count >= CONFIG.max_invites then
        return false
    end

    list[player.UserId] = { from = player, at = now }
    net.trade.invited:fire(target, player.UserId)

    return true
end

function trade.answer(player: Player, from_id: number, accept: boolean): boolean
    local remote = cross_service.answer(player, from_id, accept)
    if remote ~= nil then
        return remote
    end

    local list = invites[player]
    local invite = if list then list[from_id] else nil
    if list == nil or invite == nil then
        return false
    end

    list[from_id] = nil
    if os.clock() - invite.at > CONFIG.invite_timeout then
        return false
    end

    local from = invite.from
    if not accept or busy(player) or busy(from) or from.Parent ~= players then
        return false
    end

    local entry: Trade = {
        id = http_service:GenerateGUID(false),
        session = negotiation.new(http_service:GenerateGUID(false), from.UserId, player.UserId),
        a = from,
        b = player,
        status = "negotiating",
        reason = nil,
        closes_at = nil,
    }
    active[from] = entry
    active[player] = entry
    push(entry)

    return true
end

function trade.offer_item(player: Player, item_id: string, add: boolean): boolean
    if not add then
        return apply(player, { kind = "remove", item_id = item_id })
    end

    local entry = profiles.get(player)
    local item = if entry then entry.account.data.items[item_id] else nil
    if item == nil then
        return false
    end

    return apply(player, { kind = "add", item_id = item_id, item = { kind = item.kind } })
end

function trade.offer_coins(player: Player, amount: number): boolean
    local entry = profiles.get(player)
    if entry == nil or entry.account.data.coins < amount then
        return false
    end

    return apply(player, { kind = "coins", amount = amount })
end

function trade.accept(player: Player, version: number): boolean
    return apply(player, { kind = "accept", version = version })
end

function trade.cancel(player: Player): boolean
    return apply(player, { kind = "cancel" })
end

local function tick()
    local now = os.clock()
    local seen: { [Trade]: boolean } = {}
    for _, entry in active do
        if seen[entry] then
            continue
        end

        seen[entry] = true
        if entry.status == "negotiating" and negotiation.tick(entry.session, now) then
            task.spawn(execute, entry)
        elseif entry.closes_at and now >= entry.closes_at then
            for _, player in { entry.a, entry.b } do
                if active[player] == entry then
                    active[player] = nil
                end
            end
        end
    end
end

local function sweep()
    for player in active do
        if player.Parent ~= players then
            active[player] = nil
        end
    end

    for _, player in players:GetPlayers() do
        local entry = profiles.get(player)
        if entry and next(entry.account.data.escrow) then
            task.spawn(protocol.recover, ports, entry.account)
        end
    end
end

function trade.start()
    local t = guard.t
    local limiter = guard.limiter()
    local user_id = t.integer(1, MAX_USER_ID)

    net.trade.invite:on(guard.handler("trade.invite", limiter, { user_id }, trade.invite))
    net.trade.answer:on(guard.handler("trade.answer", limiter, { user_id, t.boolean }, trade.answer))
    net.trade.offer_item:on(guard.handler("trade.offer_item", limiter, { t.id, t.boolean }, trade.offer_item))
    net.trade.offer_coins:on(
        guard.handler("trade.offer_coins", limiter, { t.integer(0, CONFIG.max_coins_per_side) }, trade.offer_coins)
    )
    net.trade.accept:on(guard.handler("trade.accept", limiter, { t.integer(1, MAX_VERSION) }, trade.accept))
    net.trade.cancel:on(guard.handler("trade.cancel", limiter, {}, trade.cancel))

    profiles.on_loaded(function(_, entry)
        protocol.recover(ports, entry.account)
    end)

    cross_service.start({
        ports = ports,
        coord = coordinator.memory_store({
            map_name = if run_service:IsStudio()
                then CONFIG.coordinator_map .. tuning.profiles.studio_suffix
                else CONFIG.coordinator_map,
            maps = CONFIG.coordinator_maps,
            presence_ttl = CONFIG.presence_ttl,
            session_ttl = CONFIG.session_ttl,
            closed_ttl = CONFIG.closed_ttl,
            backoff_base = CONFIG.backoff_base,
            backoff_cap = CONFIG.backoff_cap,
        }),
        busy = function(player)
            return active[player] ~= nil
        end,
        emit = function(kind, tx_id, reason, seconds, player)
            emit({ kind = kind, tx_id = tx_id, reason = reason, seconds = seconds, players = { player }, cross = true })
        end,
    })
    gift_service.start()
    inventory.start()

    players.PlayerRemoving:Connect(function(player)
        invites[player] = nil
        last_invite[player] = nil
        local entry = negotiating(player)
        if entry then
            negotiation.apply(entry.session, player.UserId, { kind = "cancel" }, os.clock())
            finish(entry, "aborted", "left")
        end
    end)

    task.spawn(function()
        while true do
            task.wait(CONFIG.tick_interval)
            tick()
        end
    end)

    task.spawn(function()
        while true do
            task.wait(CONFIG.sweep_interval)
            sweep()
        end
    end)
end

return trade
