--!strict

local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")
local run_service = game:GetService("RunService")

local gift = require(script.Parent.gift)
local guard = require(script.Parent.Parent.net.guard)
local inbox = require(script.Parent.inbox)
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
local inbox_store = inbox.open(
    if run_service:IsStudio() then CONFIG.inbox_store .. tuning.profiles.studio_suffix else CONFIG.inbox_store,
    CONFIG.inbox_cap
)

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

function gift_service.reserved(send: gift.Send): gift.Send
    return function(to, message)
        return inbox_store.reserve(to, message.tx_id) and send(to, message)
    end
end

function gift_service.deliver(account: types.Account, send: gift.Send?): number
    if delivering[account.user_id] then
        return 0
    end

    delivering[account.user_id] = true
    local ok, delivered = pcall(deliver, account, send or gift_service.reserved(profiles.message))
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

local function covers(saved: { [string]: number }, settled: { [string]: number }): boolean
    for from, seq in saved do
        if (settled[from] or 0) < seq then
            return false
        end
    end

    return true
end

function gift_service.receive(loaded: profiles.Loaded)
    local settled = table.clone(loaded.account.data.gift_seen)
    if next(settled) then
        task.spawn(inbox_store.settle, loaded.user_id, settled)
    end

    loaded.profile.OnAfterSave:Connect(function(last_saved: types.Data)
        if not covers(last_saved.gift_seen, settled) then
            settled = table.clone(last_saved.gift_seen)
            task.spawn(inbox_store.settle, loaded.user_id, settled)
        end
    end)

    local save_queued = false
    loaded.profile:MessageHandler(function(message: any, processed: () -> ())
        local is_gift = gift.is_gift(message)
        if is_gift and gift.receive(loaded.account.data, message) then
            trace("gift", `{message.tx_id} received by {loaded.user_id}`)
        end

        processed()
        if is_gift and not save_queued then
            save_queued = true
            task.delay(CONFIG.inbox_settle_delay, function()
                save_queued = false
                if loaded.profile:IsActive() then
                    loaded.profile:Save()
                end
            end)
        end
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
