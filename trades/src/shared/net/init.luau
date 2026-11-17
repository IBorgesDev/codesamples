--!strict

local replicated_storage = game:GetService("ReplicatedStorage")
local run_service = game:GetService("RunService")

local remote = require(script.remote)

local tree = {
    trade = {
        invite = remote.to_server(),
        answer = remote.to_server(),
        offer_item = remote.to_server(),
        offer_coins = remote.to_server(),
        accept = remote.to_server(),
        cancel = remote.to_server(),
        gift = remote.to_server(),
        invited = remote.to_client(),
        view = remote.state(),
        inventory = remote.state(),
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
