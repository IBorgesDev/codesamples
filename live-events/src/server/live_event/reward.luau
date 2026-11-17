--!strict

local types = require(script.Parent.types)

local reward = {}

function reward.reached(snapshot: types.Snapshot?): boolean
    return snapshot ~= nil and snapshot.completed_at ~= nil
end

function reward.grant(data: types.PlayerData, event_id: string, coins: number, now: number): boolean
    if data.live_rewards[event_id] ~= nil then
        return false
    end

    data.coins += coins
    data.live_rewards[event_id] = now

    return true
end

return reward
