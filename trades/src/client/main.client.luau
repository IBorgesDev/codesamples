--!strict

local replicated_storage = game:GetService("ReplicatedStorage")

require(replicated_storage.Shared.net)

require(script.Parent.trade.store).start()
require(script.Parent.trade.ui).start()
