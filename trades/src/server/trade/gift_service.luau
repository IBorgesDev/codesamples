--!strict

local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")

local gift = require(script.Parent.gift)
local guard = require(script.Parent.Parent.net.guard)
local net = require(replicated_storage.Shared.net)
local profiles = require(script.Parent.Parent.data.profiles)
local trace = require(replicated_storage.Shared.util.trace)
local tuning = require(replicated_storage.Shared.config.tuning)
local types = require(script.Parent.types)

const CONFIG = tuning.trade
const MAX_USER_ID = 2 ^ 53

local gift_service = {}

local delivering: { [number]: boolean } = {}
local listeners: { (Player, number, number) -> () } = {}

function gift_service.on_sent(listener: (Player, number, number) -> ())
    table.insert(listeners, listener)
end

local function durable(ids: { string }): (types.Data) -> boolean
    return function(saved)
        for _, tx_id in ids do
            if saved.outbox[tx_id] == nil then
                return false
            end
        end

        return true
    end
end

local function deliver(account: types.Account, send: gift.Send): number
    local ids = gift.pending(account.data)
    if #ids == 0 or not account.persist(durable(ids)) then
        return 0
    end

    return gift.deliver(account.data, ids, send, account.active)
end

function gift_service.deliver(account: types.Account, send: gift.Send?): number
    if delivering[account.user_id] then
        return 0
    end

    delivering[account.user_id] = true
    local ok, delivered = pcall(deliver, account, send or profiles.message)
    delivering[account.user_id] = nil

    if not ok then
        trace("gift", `delivery for {account.user_id} failed: {delivered}`)
        return 0
    end

    return delivered
end

function gift_service.send(player: Player, to: number, coins: number, item_ids: { string }): boolean
    local loaded = profiles.get(player)
    if loaded == nil or to == player.UserId or (coins == 0 and #item_ids == 0) then
        return false
    end

    local data = loaded.account.data
    local queued = 0
    for _ in data.outbox do
        queued += 1
    end

    if queued >= CONFIG.max_outbox then
        return false
    end

    local items: types.Items = {}
    for _, item_id in item_ids do
        local item = data.items[item_id]
        if item == nil or items[item_id] then
            return false
        end

        items[item_id] = item
    end

    local tx_id = gift.send(data, player.UserId, to, coins, items, os.time())
    if tx_id == nil then
        return false
    end

    trace("gift", `{tx_id} to {to}`)
    task.spawn(gift_service.deliver, loaded.account)
    for _, listener in listeners do
        task.spawn(listener, player, coins, #item_ids)
    end

    return true
end

function gift_service.receive(loaded: profiles.Loaded)
    loaded.profile:MessageHandler(function(message: any, processed: () -> ())
        if gift.is_gift(message) and gift.receive(loaded.account.data, message) then
            trace("gift", `{message.tx_id} received by {loaded.user_id}`)
        end

        processed()
    end)
end

function gift_service.start()
    local t = guard.t
    net.trade.gift:on(guard.handler("trade.gift", guard.limiter(), {
        t.integer(1, MAX_USER_ID),
        t.integer(0, CONFIG.max_coins_per_side),
        t.array(t.id, CONFIG.max_items_per_side),
    }, gift_service.send))

    profiles.on_loaded(function(_, loaded)
        gift_service.receive(loaded)
        gift_service.deliver(loaded.account)
    end)

    task.spawn(function()
        while true do
            task.wait(CONFIG.gift_resend_interval)
            for _, player in players:GetPlayers() do
                local loaded = profiles.get(player)
                if loaded and next(loaded.account.data.outbox) then
                    task.spawn(gift_service.deliver, loaded.account)
                end
            end
        end
    end)
end

return gift_service
