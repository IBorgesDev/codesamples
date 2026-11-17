--!strict

local replicated_storage = game:GetService("ReplicatedStorage")

local net = require(replicated_storage.Shared.net)
local tuning = require(replicated_storage.Shared.config.tuning)

export type Side = {
    user_id: number?,
    coins: number,
    items: { [string]: string },
    accepted: boolean,
}

export type View = {
    id: string,
    status: string,
    reason: string?,
    version: number,
    lock_in: number?,
    accept_in: number?,
    me: Side,
    them: Side,
}

export type Inventory = {
    coins: number,
    items: { [string]: string },
}

export type Invite = {
    from: number,
    at: number,
}

export type State = {
    view: View?,
    view_at: number,
    dismissed: string?,
    inventory: Inventory,
    invites: { Invite },
}

local store = {}

local state: State = {
    view = nil,
    view_at = 0,
    dismissed = nil,
    inventory = { coins = 0, items = {} },
    invites = {},
}
local listeners: { (State) -> () } = {}

local function changed()
    for _, listener in listeners do
        task.spawn(listener, state)
    end
end

local function drop_invite(from: number)
    for index = #state.invites, 1, -1 do
        if state.invites[index].from == from then
            table.remove(state.invites, index)
        end
    end
end

local function prune()
    local now = os.clock()
    for index = #state.invites, 1, -1 do
        if now - state.invites[index].at > tuning.trade.invite_timeout then
            table.remove(state.invites, index)
        end
    end
end

function store.state(): State
    return state
end

function store.on_change(listener: (State) -> ())
    table.insert(listeners, listener)
end

function store.active(): View?
    local view = state.view
    if view == nil or view.id == state.dismissed then
        return nil
    end

    return view
end

local function valid_user(user_id: number): boolean
    return user_id % 1 == 0 and user_id >= 1
end

local function coins_to_offer(amount: number): number
    local floored = math.floor(amount)
    if floored ~= floored then
        return 0
    end

    return math.clamp(floored, 0, math.min(state.inventory.coins, tuning.trade.max_coins_per_side))
end

function store.accept_in(): number
    local view = state.view
    if view == nil or view.accept_in == nil then
        return 0
    end

    return math.max(0, view.accept_in - (os.clock() - state.view_at))
end

function store.invite(user_id: number): boolean
    return valid_user(user_id) and net.trade.invite:fire(user_id)
end

function store.answer(from: number, accept: boolean)
    drop_invite(from)
    if valid_user(from) then
        net.trade.answer:fire(from, accept)
    end

    changed()
end

function store.offer_item(item_id: string, add: boolean)
    net.trade.offer_item:fire(item_id, add)
end

function store.offer_coins(amount: number)
    net.trade.offer_coins:fire(coins_to_offer(amount))
end

function store.accept()
    local view = state.view
    if view and store.accept_in() <= 0 then
        net.trade.accept:fire(view.version)
    end
end

function store.cancel()
    net.trade.cancel:fire()
end

function store.dismiss()
    local view = state.view
    if view then
        state.dismissed = view.id
        changed()
    end
end

function store.gift(to: number, coins: number, item_ids: { string }): boolean
    if not valid_user(to) or #item_ids > tuning.trade.max_items_per_side then
        return false
    end

    return net.trade.gift:fire(to, coins_to_offer(coins), item_ids)
end

function store.start()
    net.trade.view:observe(function(view: View)
        state.view = view
        state.view_at = os.clock()
        changed()
    end)

    net.trade.inventory:observe(function(inventory: Inventory)
        state.inventory = inventory
        changed()
    end)

    net.trade.invited:on(function(from: number)
        prune()
        drop_invite(from)
        table.insert(state.invites, { from = from, at = os.clock() })
        changed()
    end)
end

return store
