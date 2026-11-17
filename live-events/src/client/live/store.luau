--!strict

local replicated_storage = game:GetService("ReplicatedStorage")

local net = require(replicated_storage.Shared.net)

export type View = {
    state: string,
    totals: { [string]: number },
    servers: number,
}

export type Mine = {
    votes: { [string]: { option: string, here: boolean } },
    rewards: { [string]: boolean },
}

local store = {}

local views: { [string]: View } = {}
local mine: Mine = { votes = {}, rewards = {} }
local mine_loaded = false
local listeners: { () -> () } = {}
local reward_listeners: { (string) -> () } = {}

local function changed()
    for _, listener in listeners do
        task.spawn(listener)
    end
end

local function update(event_id: string, state: string, totals: { [string]: number }, servers: number)
    views[event_id] = { state = state, totals = totals, servers = servers }
    changed()
end

function store.view(event_id: string): View?
    return views[event_id]
end

function store.mine(): Mine
    return mine
end

function store.on_change(listener: () -> ())
    table.insert(listeners, listener)
end

function store.on_reward(listener: (string) -> ())
    table.insert(reward_listeners, listener)
end

function store.vote(event_id: string, option: string): boolean
    local current = mine.votes[event_id]
    if current and current.option == option then
        return true
    end

    return net.live.vote:fire(event_id, option)
end

function store.start()
    net.live.progress:on(update)
    net.live.sync:on(function(list: { { id: string, state: string, totals: { [string]: number }, servers: number } })
        for _, item in list do
            views[item.id] = { state = item.state, totals = item.totals, servers = item.servers }
        end

        changed()
    end)

    net.live.mine:observe(function(next_mine: Mine)
        if mine_loaded then
            for event_id in next_mine.rewards do
                if not mine.rewards[event_id] then
                    for _, listener in reward_listeners do
                        task.spawn(listener, event_id)
                    end
                end
            end
        end

        mine = next_mine
        mine_loaded = true
        changed()
    end)
end

return store
