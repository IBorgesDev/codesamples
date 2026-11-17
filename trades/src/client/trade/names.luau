--!strict

local players = game:GetService("Players")

local names = {}

local known: { [number]: string } = {}
local asking: { [number]: boolean } = {}

function names.get(user_id: number, on_ready: () -> ()): string
    local name = known[user_id]
    if name then
        return name
    end

    local player = players:GetPlayerByUserId(user_id)
    if player then
        known[user_id] = player.DisplayName
        return player.DisplayName
    end

    if not asking[user_id] then
        asking[user_id] = true
        task.spawn(function()
            local ok, result = pcall(function()
                return players:GetNameFromUserIdAsync(user_id)
            end)

            known[user_id] = if ok then result else `Player {user_id}`
            on_ready()
        end)
    end

    return `Player {user_id}`
end

return names
