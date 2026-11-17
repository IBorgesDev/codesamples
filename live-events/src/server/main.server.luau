--!strict

local replicated_storage = game:GetService("ReplicatedStorage")
local run_service = game:GetService("RunService")

require(replicated_storage.Shared.net)
require(script.Parent.net.guard).start()
require(script.Parent.data.profiles).start()
require(script.Parent.live_event.service).start()

if run_service:IsStudio() then
    require(script.Parent.dev.live_demo)()
    require(script.Parent.dev.stress)()
end
