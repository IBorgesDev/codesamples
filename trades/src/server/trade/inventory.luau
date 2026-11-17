--!strict

local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")

local every = require(script.Parent.Parent.util.every)
local net = require(replicated_storage.Shared.net)
local profiles = require(script.Parent.Parent.data.profiles)
local tuning = require(script.Parent.Parent.config.tuning)
local types = require(script.Parent.types)

export type Snapshot = {
    coins: number,
    items: { [string]: string },
}

local inventory = {}

local sent: { [Player]: string } = {}

function inventory.snapshot(data: types.Data): (Snapshot, string)
    local items: { [string]: string } = {}
    local ids = {}
    for item_id, item in data.items do
        items[item_id] = item.kind
        table.insert(ids, item_id)
    end

    table.sort(ids)

    return { coins = data.coins, items = items }, `{data.coins}|{table.concat(ids, ",")}`
end

local function sync(player: Player)
    local loaded = profiles.get(player)
    if loaded == nil then
        return
    end

    local snapshot, fingerprint = inventory.snapshot(loaded.account.data)
    if sent[player] ~= fingerprint then
        sent[player] = fingerprint
        net.trade.inventory:set(player, snapshot)
    end
end

function inventory.start()
    profiles.on_loaded(function(player)
        sync(player)
    end)

    players.PlayerRemoving:Connect(function(player)
        sent[player] = nil
    end)

    every("inventory", tuning.trade.inventory_interval, function()
        for _, player in players:GetPlayers() do
            sync(player)
        end
    end)
end

return inventory
