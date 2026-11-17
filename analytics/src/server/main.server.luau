--!strict

local run_service = game:GetService("RunService")

require(script.Parent.analytics.service).start()

if run_service:IsStudio() then
    task.defer(require(script.Parent.dev.tests))
    require(script.Parent.dev.demo)()
end
