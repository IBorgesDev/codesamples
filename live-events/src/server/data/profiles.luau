--!strict

local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")
local run_service = game:GetService("RunService")
local server_script_service = game:GetService("ServerScriptService")

local profile_store = require(server_script_service.ServerPackages.ProfileStore)
local trace = require(replicated_storage.Shared.util.trace)
local tuning = require(replicated_storage.Shared.config.tuning)
local types = require(script.Parent.Parent.live_event.types)

const CONFIG = tuning.profiles

export type Loaded = {
    user_id: number,
    profile: any,
    account: types.Account,
}

local profiles = {}

local template: types.PlayerData = {
    coins = 0,
    live_votes = {},
    live_rewards = {},
}
local store_name = if run_service:IsStudio() then CONFIG.store_name .. CONFIG.studio_suffix else CONFIG.store_name
local store = profile_store.New(store_name, template)
local loaded: { [Player]: Loaded } = {}
local listeners: { (Player, Loaded) -> () } = {}

local function account(user_id: number, profile: any): types.Account
    return {
        user_id = user_id,
        data = profile.Data,
        active = function()
            return profile:IsActive()
        end,
        persist = function(durable)
            if not profile:IsActive() then
                return false
            end

            local done = false
            local landed = false
            local saved = profile.OnAfterSave:Connect(function(last_saved)
                if durable(last_saved) then
                    landed = true
                    done = true
                end
            end)
            local ended = profile.OnSessionEnd:Connect(function()
                done = true
            end)

            profile:Save()
            local deadline = os.clock() + CONFIG.persist_timeout
            while not done and os.clock() < deadline do
                task.wait()
            end

            saved:Disconnect()
            ended:Disconnect()

            return landed
        end,
    }
end

function profiles.get(player: Player): Loaded?
    return loaded[player]
end

function profiles.on_loaded(listener: (Player, Loaded) -> ())
    table.insert(listeners, listener)
    for player, entry in loaded do
        task.spawn(listener, player, entry)
    end
end

local function load(player: Player)
    local profile = store:StartSessionAsync(
        `player_{player.UserId}`,
        {
            Cancel = function()
                return player.Parent ~= players
            end,
        } :: any
    )

    if profile == nil then
        if player.Parent == players then
            player:Kick("Your data could not be loaded. Please rejoin.")
        end

        return
    end

    profile:Reconcile()
    profile:AddUserId(player.UserId)
    profile.OnSessionEnd:Connect(function()
        loaded[player] = nil
        if player.Parent == players then
            player:Kick("Your data was opened on another server. Please rejoin.")
        end
    end)

    if player.Parent ~= players then
        profile:EndSession()
        return
    end

    local entry = { user_id = player.UserId, profile = profile, account = account(player.UserId, profile) }
    loaded[player] = entry
    trace("profiles", `loaded {player.UserId}`)
    for _, listener in listeners do
        task.spawn(listener, player, entry)
    end
end

function profiles.start()
    players.PlayerAdded:Connect(load)
    for _, player in players:GetPlayers() do
        task.spawn(load, player)
    end

    players.PlayerRemoving:Connect(function(player)
        local entry = loaded[player]
        if entry then
            entry.profile:EndSession()
        end
    end)
end

return profiles
