--!strict

local http_service = game:GetService("HttpService")
local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")

local coordinator = require(script.Parent.coordinator)
local cross_service = require(script.Parent.cross_service)
local every = require(script.Parent.Parent.util.every)
local gift_service = require(script.Parent.gift_service)
local guard = require(script.Parent.Parent.net.guard)
local inventory = require(script.Parent.inventory)
local invites = require(script.Parent.invites)
local negotiation = require(script.Parent.negotiation)
local net = require(replicated_storage.Shared.net)
local profiles = require(script.Parent.Parent.data.profiles)
local protocol = require(script.Parent.protocol)
local records = require(script.Parent.records)
local stat = require(script.Parent.Parent.dev.stats)
local store_name = require(script.Parent.Parent.data.store_name)
local trace = require(script.Parent.Parent.util.trace)
local tuning = require(script.Parent.Parent.config.tuning)
local types = require(script.Parent.types)
local view = require(script.Parent.view)

const CONFIG = tuning.trade
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

local trade = {}

local active: { [Player]: Trade } = {}
local open_trades: { [Trade]: boolean } = {}
local last_invite: { [Player]: number } = {}
local pending_invites: invites.Book<Player> = invites.book(CONFIG.max_invites, CONFIG.invite_timeout)
local lock_limiter = guard.limiter(CONFIG.lock_pace)

local ports: types.Ports = {
    records = records.open(store_name(CONFIG.store_name)),
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

local function push(entry: Trade)
    for _, player in { entry.a, entry.b } do
        if player.Parent == players then
            net.trade.view:set(
                player,
                view.of(entry.id, entry.status, entry.reason, entry.session, player.UserId, os.clock(), math.huge)
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

local function settle(entry: Trade): (string, string?)
    local a, b = profiles.get(entry.a), profiles.get(entry.b)
    if a == nil or b == nil then
        return "aborted", "left"
    end

    if
        records.budget() < CONFIG.min_update_budget or not (lock_limiter:take(entry.a) and lock_limiter:take(entry.b))
    then
        return "aborted", "busy"
    end

    local tx_id = http_service:GenerateGUID(false)
    local started = os.clock()
    local session = entry.session
    local outcome, why = protocol.run(
        ports,
        a.account,
        b.account,
        tx_id,
        negotiation.side(session.a),
        negotiation.side(session.b),
        session.version
    )
    local seconds = os.clock() - started
    stat("trade.last_seconds", math.round(seconds * 1000) / 1000)
    trace("trade", `{tx_id} {outcome} {why or ""} in {math.round(seconds * 1000)} ms`)

    return outcome, why
end

local function execute(entry: Trade)
    entry.status = "locking"
    push(entry)

    local ok, outcome, why = pcall(settle, entry)
    if not ok then
        warn(`[trade] {entry.id} failed while locking: {outcome}`)
        finish(entry, "pending", nil)
    elseif outcome == "committed" then
        finish(entry, "committed", nil)
    else
        finish(entry, view.status_of(outcome), why)
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
    if cross_service.busy(player) then
        return cross_service.apply(player, op)
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

local function open(a: Player, b: Player)
    local id = http_service:GenerateGUID(false)
    local entry: Trade = {
        id = id,
        session = negotiation.new(id, a.UserId, b.UserId),
        a = a,
        b = b,
        status = "negotiating",
        reason = nil,
        closes_at = nil,
    }
    active[a] = entry
    active[b] = entry
    open_trades[entry] = true
    push(entry)
end

local function close(entry: Trade)
    open_trades[entry] = nil
    for _, player in { entry.a, entry.b } do
        if active[player] == entry then
            active[player] = nil
        end
    end
end

function trade.invite(player: Player, target_id: number): boolean
    local now = os.clock()
    if
        busy(player)
        or not profiles.get(player)
        or target_id == player.UserId
        or now - (last_invite[player] or -math.huge) < CONFIG.invite_cooldown
    then
        return false
    end

    last_invite[player] = now
    local target = players:GetPlayerByUserId(target_id)
    if target == nil then
        return cross_service.invite(player, target_id)
    end

    if busy(target) or not profiles.get(target) or not pending_invites.offer(target, player.UserId, player, now) then
        return false
    end

    net.trade.invited:fire(target, player.UserId)

    return true
end

function trade.answer(player: Player, from_id: number, accept: boolean): boolean
    if cross_service.invited(player, from_id) then
        return cross_service.answer(player, from_id, accept)
    end

    local from = pending_invites.take(player, from_id, os.clock())
    if from == nil or not accept or busy(player) or busy(from) or from.Parent ~= players then
        return false
    end

    open(from, player)

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
    for entry in open_trades do
        if entry.status == "negotiating" and negotiation.tick(entry.session, now) then
            task.spawn(execute, entry)
        elseif entry.closes_at and now >= entry.closes_at then
            close(entry)
        end
    end
end

local function sweep()
    for _, player in players:GetPlayers() do
        local entry = profiles.get(player)
        if entry and next(entry.account.data.escrow) then
            task.spawn(protocol.recover, ports, entry.account)
        end
    end
end

local function leave(player: Player)
    pending_invites.forget(player)
    last_invite[player] = nil
    local entry = negotiating(player)
    if entry then
        negotiation.apply(entry.session, player.UserId, { kind = "cancel" }, os.clock())
        finish(entry, "aborted", "left")
    end
end

function trade.start()
    local t = guard.t
    local limiter = guard.limiter()

    net.trade.invite:on(guard.handler("trade.invite", limiter, { t.user_id }, trade.invite))
    net.trade.answer:on(guard.handler("trade.answer", limiter, { t.user_id, t.boolean }, trade.answer))
    net.trade.offer_item:on(guard.handler("trade.offer_item", limiter, { t.id, t.boolean }, trade.offer_item))
    net.trade.offer_coins:on(
        guard.handler("trade.offer_coins", limiter, { t.integer(0, CONFIG.max_coins_per_side) }, trade.offer_coins)
    )
    net.trade.accept:on(guard.handler("trade.accept", limiter, { t.integer(1, MAX_VERSION) }, trade.accept))
    net.trade.cancel:on(guard.handler("trade.cancel", limiter, {}, trade.cancel))
    net.trade.force_accept:on(guard.decoy("trade.force_accept"))

    profiles.on_loaded(function(_, entry)
        protocol.recover(ports, entry.account)
    end)

    cross_service.start({
        ports = ports,
        coord = coordinator.memory_store(),
        busy = function(player)
            return active[player] ~= nil
        end,
        lock_limiter = lock_limiter,
    })
    gift_service.start()
    inventory.start()

    players.PlayerRemoving:Connect(leave)
    every("trade tick", CONFIG.tick_interval, tick)
    every("trade sweep", CONFIG.sweep_interval, sweep)
end

return trade
