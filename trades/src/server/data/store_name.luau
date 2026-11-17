--!strict

local run_service = game:GetService("RunService")

local tuning = require(script.Parent.Parent.config.tuning)

const SUFFIX = if run_service:IsStudio() then tuning.profiles.studio_suffix else ""

return function(name: string): string
    return name .. SUFFIX
end
