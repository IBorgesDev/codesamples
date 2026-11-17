--!strict

local replicated_storage = game:GetService("ReplicatedStorage")

require(replicated_storage.Shared.net)

require(script.Parent.live.store).start()
require(script.Parent.live.ui).start()
