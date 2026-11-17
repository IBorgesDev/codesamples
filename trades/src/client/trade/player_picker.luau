--!strict

local players = game:GetService("Players")

local create = require(script.Parent.Parent.ui.create)
local kit = require(script.Parent.Parent.ui.kit)
local notices = require(script.Parent.Parent.ui.notices)

const WIDTH = 360
const HEIGHT = 440
const ROSTER_HEIGHT = 200
const ROSTER_GAP = 6
const SCROLL_BAR = 4

local theme = kit.theme

export type Picker = {
    render: (title: string?) -> (),
}

local player_picker = {}

local function row(order: number, parent: Instance, layout: Instance): Frame
    return create("Frame", {
        Size = UDim2.new(1, 0, 0, theme.BUTTON_HEIGHT),
        BackgroundTransparency = 1,
        LayoutOrder = order,
        Parent = parent,
    }, { layout })
end

function player_picker.new(gui: Instance, on_pick: (user_id: number) -> (), on_close: () -> ()): Picker
    local local_player = players.LocalPlayer
    local window = kit.window("Picker", WIDTH, HEIGHT, gui)
    kit.stack(Enum.FillDirection.Vertical).Parent = window

    local heading = kit.title(1, window)
    kit.caption("Players on this server", 2, window)
    local roster: ScrollingFrame = create("ScrollingFrame", {
        Size = UDim2.new(1, 0, 0, ROSTER_HEIGHT),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = SCROLL_BAR,
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        CanvasSize = UDim2.new(),
        LayoutOrder = 3,
        Parent = window,
    }, { kit.stack(Enum.FillDirection.Vertical, ROSTER_GAP) })
    kit.caption("Or a user id on another server", 4, window)

    local remote_row = row(5, window, kit.stack(Enum.FillDirection.Horizontal))
    local user_box: TextBox = create("TextBox", {
        Size = UDim2.new(1, -(theme.NARROW_BUTTON + theme.GAP), 1, 0),
        BackgroundColor3 = theme.RAISED,
        FontFace = theme.FONT,
        PlaceholderText = "User id",
        PlaceholderColor3 = theme.MUTED,
        Text = "",
        TextColor3 = theme.INK,
        TextSize = theme.BODY_SIZE,
        TextXAlignment = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false,
        LayoutOrder = 1,
        Parent = remote_row,
    }, { kit.corner(theme.SMALL_CORNER), kit.padding(theme.GAP) })

    kit.button("Go", theme.ACCENT, theme.NARROW_BUTTON, function()
        local user_id = tonumber(user_box.Text)
        if user_id and user_id > 0 and user_id % 1 == 0 and user_id ~= local_player.UserId then
            user_box.Text = ""
            on_pick(user_id)
        else
            notices.show("Type a valid user id")
        end
    end, remote_row, 2)

    local footer = row(
        6,
        window,
        create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            HorizontalAlignment = Enum.HorizontalAlignment.Right,
            Padding = UDim.new(0, theme.GAP),
        })
    )
    kit.button("Close", theme.RAISED, theme.BUTTON_WIDTH, on_close, footer)

    local function others(): { Instance }
        local entries: { Instance } = {}
        for _, other in players:GetPlayers() do
            if other ~= local_player then
                local width = WIDTH - 2 * theme.EDGE - theme.GAP
                table.insert(
                    entries,
                    kit.button(other.DisplayName, theme.RAISED, width, function()
                        on_pick(other.UserId)
                    end)
                )
            end
        end

        if #entries == 0 then
            table.insert(
                entries,
                kit.text({
                    Text = "Nobody else is here yet",
                    TextColor3 = theme.MUTED,
                    Size = UDim2.new(1, 0, 0, theme.LINE_HEIGHT),
                })
            )
        end

        return entries
    end

    return {
        render = function(title)
            window.Visible = title ~= nil
            if title then
                heading.Text = title
                kit.refill(roster, others())
            end
        end,
    }
end

return player_picker
