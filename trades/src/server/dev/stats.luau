--!strict

local run_service = game:GetService("RunService")
local server_storage = game:GetService("ServerStorage")

const ENABLED = run_service:IsStudio()
local folder: Folder? = nil

local function get_folder(): Folder
    if folder then
        return folder
    end

    local created = Instance.new("Folder")
    created.Name = "DevStats"
    created.Parent = server_storage
    folder = created

    return created
end

local function attribute_name(name: string): string
    return (string.gsub(name, "[^%w_]", "_"))
end

return function(name: string, value: number | string | boolean)
    if not ENABLED then
        return
    end

    get_folder():SetAttribute(attribute_name(name), value)
end
