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

function store.invite(user_id: number)
    net.trade.invite:fire(user_id)
end

function store.answer(from: number, accept: boolean)
    drop_invite(from)
    net.trade.answer:fire(from, accept)
    changed()
end

function store.offer_item(item_id: string, add: boolean)
    net.trade.offer_item:fire(item_id, add)
end

function store.offer_coins(amount: number)
    net.trade.offer_coins:fire(math.clamp(math.floor(amount), 0, state.inventory.coins))
end

function store.accept()
    local view = state.view
    if view then
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

function store.gift(to: number, coins: number, item_ids: { string })
    net.trade.gift:fire(to, math.clamp(math.floor(coins), 0, state.inventory.coins), item_ids)
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
