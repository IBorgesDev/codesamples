--!strict

local players = game:GetService("Players")
local run_service = game:GetService("RunService")
local server_script_service = game:GetService("ServerScriptService")

local analytics = require(script.Parent.Parent.analytics.service)

const ATTRIBUTE = "AnalyticsDemo"
const TICK = 1
const OUTCOMES = { "committed", "committed", "committed", "aborted", "refused" }
const BOSSES = { "kraken", "megalodon", "leviathan" }
const MAX_TRADE_SECONDS = 6
const CROSS_SERVER_SHARE = 0.2
const MAX_GIFT_COINS = 50
const MAX_GIFT_ITEMS = 3
const MAX_FISH = 5
const PRODUCT_ID = 1
const PRODUCT_ROBUX = 25

local random = Random.new()

local function pick<T>(list: { T }): T
    return list[random:NextInteger(1, #list)]
end

const SAMPLES: { { chance: number, track: (Player) -> () } } = {
    {
        chance = 0.2,
        track = function(player)
            analytics.track("trade_completed", player, {
                outcome = pick(OUTCOMES),
                seconds = random:NextNumber(1, MAX_TRADE_SECONDS),
                cross_server = random:NextNumber() < CROSS_SERVER_SHARE,
            })
        end,
    },
    {
        chance = 0.05,
        track = function(player)
            analytics.track("gift_sent", player, {
                coins = random:NextInteger(0, MAX_GIFT_COINS),
                items = random:NextInteger(0, MAX_GIFT_ITEMS),
            })
        end,
    },
    {
        chance = 0.9,
        track = function(player)
            analytics.track(
                "live_contribution",
                player,
                { event_id = "world_fishing", amount = random:NextInteger(1, MAX_FISH) }
            )
        end,
    },
    {
        chance = 0.02,
        track = function(player)
            analytics.track("live_vote", player, { event_id = "boss_vote", option = pick(BOSSES) })
        end,
    },
    {
        chance = 0.01,
        track = function(player)
            analytics.track("purchase", player, { product_id = PRODUCT_ID, robux = PRODUCT_ROBUX })
        end,
    },
}

return function()
    if not run_service:IsStudio() then
        return
    end

    task.spawn(function()
        while true do
            task.wait(TICK)
            if server_script_service:GetAttribute(ATTRIBUTE) ~= true then
                continue
            end

            for _, player in players:GetPlayers() do
                for _, sample in SAMPLES do
                    if random:NextNumber() < sample.chance then
                        sample.track(player)
                    end
                end
            end
        end
    end)
end
