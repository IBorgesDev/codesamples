--!strict

local run_service = game:GetService("RunService")

const ENABLED = run_service:IsStudio()

return function(tag: string, message: string)
    if ENABLED then
        print(string.format("[%s %.3f] %s", tag, workspace:GetServerTimeNow() % 1000, message))
    end
end
