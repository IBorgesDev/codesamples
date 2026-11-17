--!strict

local replicated_storage = game:GetService("ReplicatedStorage")

local create = require(script.Parent.Parent.ui.create)
local kit = require(script.Parent.Parent.ui.kit)
local names = require(script.Parent.names)
local notices = require(script.Parent.Parent.ui.notices)
local store = require(script.Parent.store)
local tuning = require(replicated_storage.Shared.config.tuning)

const TOAST_HEIGHT = 56

local theme = kit.theme

local invite_toasts = {}

local function toast(from: number, rerender: () -> ()): Frame
    local row = create(
        "Frame",
        { Size = UDim2.fromOffset(notices.width(), TOAST_HEIGHT), BackgroundColor3 = theme.SURFACE },
        {
            kit.corner(),
            kit.padding(theme.GAP),
            create("UIStroke", { Color = theme.LINE, Thickness = 1 }),
            kit.text({
                Text = `{names.get(from, rerender)} wants to trade`,
                Size = UDim2.new(1, -(2 * theme.NARROW_BUTTON + 2 * theme.GAP), 1, 0),
            }),
        }
    )
    local actions = create("Frame", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.fromScale(1, 0.5),
        Size = UDim2.fromOffset(2 * theme.NARROW_BUTTON + theme.GAP, theme.BUTTON_HEIGHT),
        BackgroundTransparency = 1,
        Parent = row,
    }, { kit.stack(Enum.FillDirection.Horizontal) })

    kit.button("Decline", theme.RAISED, theme.NARROW_BUTTON, function()
        store.answer(from, false)
    end, actions, 1)
    kit.button("Accept", theme.GOOD, theme.NARROW_BUTTON, function()
        store.answer(from, true)
    end, actions, 2)

    return row
end

function invite_toasts.new(rerender: () -> ()): (state: store.State) -> ()
    local column = create("Frame", {
        Name = "Invites",
        Size = UDim2.fromOffset(notices.width(), 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        LayoutOrder = 1,
        Parent = notices.column(),
    }, { kit.stack(Enum.FillDirection.Vertical) })

    return function(state)
        local now = os.clock()
        local toasts: { Instance } = {}
        for _, invite in state.invites do
            if now - invite.at <= tuning.trade.invite_timeout then
                table.insert(toasts, toast(invite.from, rerender))
            end
        end

        kit.refill(column, toasts)
    end
end

return invite_toasts
