--!strict

local run_service = game:GetService("RunService")
local server_script_service = game:GetService("ServerScriptService")

local live = require(script.Parent.Parent.live_event.service)
local trace = require(script.Parent.Parent.util.trace)

const ATTRIBUTE = "LiveEventDemo"
const TICK = 1
const REPORT_EVERY = 5
const MAX_FISH_PER_TICK = 5

return function()
    if not run_service:IsStudio() then
        return
    end

    task.spawn(function()
        local ticks = 0
        while true do
            task.wait(TICK)
            if server_script_service:GetAttribute(ATTRIBUTE) == true then
                ticks += 1
                live.contribute("world_fishing", "fish", math.random(1, MAX_FISH_PER_TICK))

                if ticks % REPORT_EVERY == 0 then
                    local display = live.display("world_fishing")
                    if display then
                        trace(
                            "live",
                            `world_fishing {display.state} v{display.version}: {display.totals.fish or 0} fish, {display.servers} server(s)`
                        )
                    else
                        trace("live", "world_fishing: no total yet")
                    end
                end
            end
        end
    end)
end
