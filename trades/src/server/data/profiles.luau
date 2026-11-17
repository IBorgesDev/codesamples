--!strict

local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")
local run_service = game:GetService("RunService")
local server_script_service = game:GetService("ServerScriptService")

local profile_store = require(server_script_service.ServerPackages.ProfileStore)
local trace = require(replicated_storage.Shared.util.trace)
local tuning = require(replicated_storage.Shared.config.tuning)
local types = require(script.Parent.Parent.trade.types)

const CONFIG = tuning.profiles

profile_store.SetConstant("MAX_MESSAGE_QUEUE", CONFIG.message_queue)

export type Loaded = {
    user_id: number,
    profile: any,
    account: types.Account,
}

local profiles = {}

local template: types.Data = {
    coins = 0,
    items = {},
    escrow = {},
    gift_seq = 0,
    gift_seen = {},
    outbox = {},
}
local store_name = if run_service:IsStudio() then CONFIG.store_name .. CONFIG.studio_suffix else CONFIG.store_name
local store = profile_store.New(store_name, template)
local loaded: { [Player]: Loaded } = {}
local listeners: { (Player, Loaded) -> () } = {}

function profiles.account(user_id: number, profile: any): types.Account
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
            local deadline = os.clock() + tuning.trade.persist_timeout
            while not done and os.clock() < deadline do
                task.wait()
            end

            saved:Disconnect()
            ended:Disconnect()

            return landed
        end,
    }
end

function profiles.open(key: string, user_id: number, cancel: (() -> boolean)?): Loaded?
    local profile = store:StartSessionAsync(key, { Cancel = cancel } :: any)
    if profile == nil then
        return nil
    end

    profile:Reconcile()

    return { user_id = user_id, profile = profile, account = profiles.account(user_id, profile) }
end

function profiles.message_key(key: string, message: any): boolean
    local ok, delivered = pcall(function()
        return store:MessageAsync(key, message)
    end)

    return ok and delivered == true
end

function profiles.message(user_id: number, message: any): boolean
    return profiles.message_key(`player_{user_id}`, message)
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
    local entry = profiles.open(`player_{player.UserId}`, player.UserId, function()
        return player.Parent ~= players
    end)

    if entry == nil then
        if player.Parent == players then
            player:Kick("Your data could not be loaded. Please rejoin.")
        end

        return
    end

    entry.profile:AddUserId(player.UserId)
    entry.profile.OnSessionEnd:Connect(function()
        loaded[player] = nil
        if player.Parent == players then
            player:Kick("Your data was opened on another server. Please rejoin.")
        end
    end)

    if player.Parent ~= players then
        entry.profile:EndSession()
        return
    end

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
