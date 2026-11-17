--!strict

local players = game:GetService("Players")
local run_service = game:GetService("RunService")

local create = require(script.Parent.Parent.ui.create)
local gift_window = require(script.Parent.gift_window)
local invite_toasts = require(script.Parent.invite_toasts)
local kit = require(script.Parent.Parent.ui.kit)
local names = require(script.Parent.names)
local notices = require(script.Parent.Parent.ui.notices)
local player_picker = require(script.Parent.player_picker)
local store = require(script.Parent.store)
local trade_window = require(script.Parent.trade_window)

type Mode = "trade" | "gift"

const PICKER_TITLE: { [Mode]: string } = {
    trade = "Trade with",
    gift = "Send a gift to",
}

local theme = kit.theme

local ui = {}

local function fit_to_viewport(scale: UIScale)
    local function fit()
        local camera = workspace.CurrentCamera
        if camera then
            local room = camera.ViewportSize - Vector2.new(2 * theme.EDGE, 2 * theme.EDGE)
            scale.Scale = math.min(1, room.X / trade_window.SIZE.X, room.Y / trade_window.SIZE.Y)
        end
    end

    fit()
    if workspace.CurrentCamera then
        workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
    end
end

function ui.start()
    local gui: ScreenGui = create("ScreenGui", {
        Name = "Trade",
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        Parent = players.LocalPlayer:WaitForChild("PlayerGui"),
    })
    fit_to_viewport(create("UIScale", { Parent = gui }))

    local mode: Mode? = nil
    local render: () -> () = function() end

    local function rerender()
        render()
    end

    local show_invites = invite_toasts.new(rerender)
    local trade = trade_window.new(gui, rerender)
    local gift = gift_window.new(gui, rerender)

    local function pick(user_id: number)
        if mode == "gift" then
            gift.open(user_id)
        elseif store.invite(user_id) then
            notices.show(`Invite sent to {names.get(user_id, rerender)}`)
        else
            notices.show("Could not send the invite, try again in a moment")
        end

        mode = nil
        render()
    end

    local function open(next_mode: Mode)
        mode = next_mode
        gift.close()
        render()
    end

    local picker = player_picker.new(gui, pick, function()
        mode = nil
        render()
    end)

    local hud = create("Frame", {
        Name = "Hud",
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, theme.EDGE, 1, -theme.EDGE),
        Size = UDim2.fromOffset(2 * theme.BUTTON_WIDTH + theme.GAP, theme.BUTTON_HEIGHT),
        BackgroundTransparency = 1,
        Parent = gui,
    }, { kit.stack(Enum.FillDirection.Horizontal) })
    kit.button("Trade", theme.ACCENT, theme.BUTTON_WIDTH, function()
        open("trade")
    end, hud, 1)
    kit.button("Gift", theme.RAISED, theme.BUTTON_WIDTH, function()
        open("gift")
    end, hud, 2)

    render = function()
        local state = store.state()
        local view = store.active()
        local picking: Mode? = if view == nil then mode else nil

        show_invites(state)
        trade.render(view, state.inventory)
        picker.render(if picking then PICKER_TITLE[picking] else nil)
        gift.render(view == nil and mode == nil, state.inventory)
    end

    store.on_change(function()
        render()
    end)

    players.PlayerAdded:Connect(rerender)
    players.PlayerRemoving:Connect(function()
        task.defer(rerender)
    end)

    local last_second = -1
    run_service.Heartbeat:Connect(function()
        local now = os.clock()
        local second = math.floor(now)
        if second ~= last_second then
            last_second = second
            show_invites(store.state())
        end

        trade.tick(now)
    end)

    render()
end

return ui
