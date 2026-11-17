--!strict

local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")

local create = require(script.Parent.create)
local kit = require(script.Parent.kit)
local tuning = require(replicated_storage.Shared.config.tuning)

const WIDTH = 380
const NOTICE_ORDER = 100
const DISPLAY_ORDER = 10

local theme = kit.theme

local notices = {}

local column: Frame? = nil

function notices.column(): Frame
    local existing = column
    if existing then
        return existing
    end

    local gui = create("ScreenGui", {
        Name = "Notices",
        ResetOnSpawn = false,
        DisplayOrder = DISPLAY_ORDER,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        Parent = players.LocalPlayer:WaitForChild("PlayerGui"),
    })
    local created: Frame = create("Frame", {
        Name = "Column",
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, 0, 0, theme.EDGE),
        Size = UDim2.fromOffset(WIDTH, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = gui,
    }, { kit.stack(Enum.FillDirection.Vertical) })
    column = created

    return created
end

function notices.width(): number
    return WIDTH
end

function notices.show(message: string, color: Color3?)
    local label = create("Frame", {
        Size = UDim2.fromOffset(WIDTH, theme.BUTTON_HEIGHT),
        BackgroundColor3 = theme.SURFACE,
        LayoutOrder = NOTICE_ORDER,
        Parent = notices.column(),
    }, {
        kit.corner(),
        kit.padding(theme.GAP),
        create("UIStroke", { Color = color or theme.LINE, Thickness = 1 }),
        kit.text({ Text = message, Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center }),
    })
    task.delay(tuning.ui.notice_seconds, function()
        label:Destroy()
    end)
end

return notices
