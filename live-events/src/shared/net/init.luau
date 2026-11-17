--!strict

local replicated_storage = game:GetService("ReplicatedStorage")
local run_service = game:GetService("RunService")

local remote = require(script.remote)

local tree = {
    live = {
        progress = remote.to_client("unreliable"),
        sync = remote.to_client(),
        vote = remote.to_server(),
        mine = remote.state(),
    },
}

const FOLDER = "Remotes"

local folder: Instance

if run_service:IsServer() then
    folder = replicated_storage:FindFirstChild(FOLDER) or Instance.new("Folder")
    folder.Name = FOLDER
    folder.Parent = replicated_storage
else
    folder = replicated_storage:WaitForChild(FOLDER)
end

remote.build(tree, folder, run_service:IsServer())

return tree
