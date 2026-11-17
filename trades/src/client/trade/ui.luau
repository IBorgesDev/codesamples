--!strict

local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")
local run_service = game:GetService("RunService")

local create = require(script.Parent.Parent.ui.create)
local item_kinds = require(replicated_storage.Shared.config.items)
local kit = require(script.Parent.Parent.ui.kit)
local names = require(script.Parent.names)
local notices = require(script.Parent.Parent.ui.notices)
local store = require(script.Parent.store)
local tuning = require(replicated_storage.Shared.config.tuning)

const RARITY = {
    Color3.fromRGB(137, 135, 129),
    Color3.fromRGB(25, 158, 112),
    Color3.fromRGB(144, 133, 233),
    Color3.fromRGB(217, 89, 38),
}
const CHIP_WIDTH = 112
const CHIP_HEIGHT = 48
const CHIP_CELL = UDim2.fromOffset(CHIP_WIDTH, CHIP_HEIGHT)
const CHIP_TEXT_SIZE = 15
const BADGE_WIDTH = 90
const ROSTER_HEIGHT = 200
const COLUMNS_HEIGHT = 170
const OFFER_HEIGHT = 118
const INVENTORY_HEIGHT = 150
const GIFT_INVENTORY_HEIGHT = 200
const GIFT_HEIGHT = 380
const RARITY_BAR = 4
const WINDOW_WIDTH = 660
const WINDOW_HEIGHT = 500
const PICKER_WIDTH = 360
const PICKER_HEIGHT = 440
const TOAST_HEIGHT = 56
const REASONS = {
    cancelled = "it was cancelled",
    left = "a player left",
    inactive = "a player left",
    busy = "the servers are busy, try again",
    expired = "it timed out",
    timeout = "it timed out",
    missing = "it timed out",
    a_silent = "the other server stopped answering",
    a_unsaved = "a save failed, nothing moved",
    b_unsaved = "a save failed, nothing moved",
    coins = "not enough coins",
    b_coins = "not enough coins",
    items = "an item is no longer there",
    b_items = "an item is no longer there",
}

local theme = kit.theme

type Mode = "trade" | "gift"

local ui = {}

local function sorted(items: { [string]: string }): { { id: string, kind: string } }
    local out = {}
    for item_id, kind in items do
        table.insert(out, { id = item_id, kind = kind })
    end

    table.sort(out, function(a, b)
        local rarity_a = if item_kinds[a.kind] then item_kinds[a.kind].rarity else 0
        local rarity_b = if item_kinds[b.kind] then item_kinds[b.kind].rarity else 0
        if rarity_a ~= rarity_b then
            return rarity_a > rarity_b
        end

        if a.kind ~= b.kind then
            return a.kind < b.kind
        end

        return a.id < b.id
    end)

    return out
end

local function chip(name: string, kind: string, selected: boolean, on_click: (() -> ())?): GuiObject
    local definition = item_kinds[kind]
    local rarity = if definition then RARITY[definition.rarity] or RARITY[1] else RARITY[1]
    local children = {
        kit.corner(theme.SMALL_CORNER),
        create("UIStroke", {
            Color = theme.ACCENT,
            Thickness = 2,
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
            Enabled = selected,
        }),
        create("Frame", {
            Size = UDim2.new(0, RARITY_BAR, 1, -2 * theme.GAP),
            Position = UDim2.fromOffset(theme.GAP, theme.GAP),
            BackgroundColor3 = rarity,
            BorderSizePixel = 0,
        }, { kit.corner(UDim.new(0, RARITY_BAR / 2)) }),
        kit.text({
            Text = if definition then definition.name else kind,
            Position = UDim2.fromOffset(2 * theme.GAP + RARITY_BAR, 0),
            Size = UDim2.new(1, -(3 * theme.GAP + RARITY_BAR), 1, 0),
            TextSize = CHIP_TEXT_SIZE,
        }),
    }

    if on_click then
        local instance = create(
            "TextButton",
            { Name = name, BackgroundColor3 = theme.RAISED, AutoButtonColor = true, Text = "" },
            children
        )
        instance.Activated:Connect(on_click)
        return instance
    end

    return create("Frame", { Name = name, BackgroundColor3 = theme.RAISED }, children)
end

local function status_of(view: store.View, them: string, now: number): (string, Color3)
    if view.status == "negotiating" then
        local lock_in = view.lock_in
        if lock_in then
            local left = math.max(0, lock_in - (now - store.state().view_at))
            return `Both accepted, locking in {math.ceil(left)}`, theme.ACCENT
        end

        if view.me.accepted then
            return `Waiting for {them} to accept`, theme.INK_2
        end

        if view.them.accepted then
            return `{them} accepted, your turn`, theme.INK_2
        end

        return "Add items or coins, then accept", theme.INK_2
    end

    if view.status == "locking" then
        return "Saving both inventories", theme.ACCENT
    end

    if view.status == "committed" then
        return "Trade complete", theme.GOOD
    end

    if view.status == "aborted" then
        local reason = view.reason
        local why = if reason then (REASONS :: { [string]: string })[reason] or reason else "it was cancelled"
        return `Trade cancelled: {why}`, theme.DANGER
    end

    return "Finishing in the background, nothing is lost", theme.INK_2
end

function ui.start()
    local player = players.LocalPlayer
    local gui: ScreenGui = create("ScreenGui", {
        Name = "Trade",
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        Parent = player:WaitForChild("PlayerGui"),
    })
    local scale: UIScale = create("UIScale", { Parent = gui })

    local mode: Mode? = nil
    local gift_target: number? = nil
    local gift_selection: { [string]: boolean } = {}
    local render: () -> () = function() end

    local function rerender()
        render()
    end

    local hud = create("Frame", {
        Name = "Hud",
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, theme.EDGE, 1, -theme.EDGE),
        Size = UDim2.fromOffset(2 * theme.BUTTON_WIDTH + theme.GAP, theme.BUTTON_HEIGHT),
        BackgroundTransparency = 1,
        Parent = gui,
    }, { kit.stack(Enum.FillDirection.Horizontal) })

    local toasts = create("Frame", {
        Name = "Invites",
        Size = UDim2.fromOffset(notices.width(), 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        LayoutOrder = 1,
        Parent = notices.column(),
    }, { kit.stack(Enum.FillDirection.Vertical) })

    local picker = kit.window("Picker", PICKER_WIDTH, PICKER_HEIGHT, gui)
    kit.stack(Enum.FillDirection.Vertical).Parent = picker
    local picker_title = kit.text({
        Text = "",
        FontFace = theme.FONT_BOLD,
        TextSize = theme.TITLE_SIZE,
        Size = UDim2.new(1, 0, 0, theme.TITLE_HEIGHT),
        LayoutOrder = 1,
        Parent = picker,
    })
    kit.text({
        Text = "Players on this server",
        TextColor3 = theme.MUTED,
        TextSize = theme.SMALL_SIZE,
        Size = UDim2.new(1, 0, 0, theme.CAPTION_HEIGHT),
        LayoutOrder = 2,
        Parent = picker,
    })
    local roster: ScrollingFrame = create("ScrollingFrame", {
        Size = UDim2.new(1, 0, 0, ROSTER_HEIGHT),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 4,
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        CanvasSize = UDim2.new(),
        LayoutOrder = 3,
        Parent = picker,
    }, { kit.stack(Enum.FillDirection.Vertical, 6) })
    kit.text({
        Text = "Or a user id on another server",
        TextColor3 = theme.MUTED,
        TextSize = theme.SMALL_SIZE,
        Size = UDim2.new(1, 0, 0, theme.CAPTION_HEIGHT),
        LayoutOrder = 4,
        Parent = picker,
    })
    local remote_row = create(
        "Frame",
        { Size = UDim2.new(1, 0, 0, theme.BUTTON_HEIGHT), BackgroundTransparency = 1, LayoutOrder = 5, Parent = picker },
        {
            kit.stack(Enum.FillDirection.Horizontal),
        }
    )
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
        Parent = remote_row,
    }, { kit.corner(theme.SMALL_CORNER), kit.padding(theme.GAP) })
    local picker_footer = create(
        "Frame",
        { Size = UDim2.new(1, 0, 0, theme.BUTTON_HEIGHT), BackgroundTransparency = 1, LayoutOrder = 6, Parent = picker },
        {
            create("UIListLayout", {
                FillDirection = Enum.FillDirection.Horizontal,
                HorizontalAlignment = Enum.HorizontalAlignment.Right,
                Padding = UDim.new(0, theme.GAP),
            }),
        }
    )

    local function pick(user_id: number)
        if mode == "trade" then
            store.invite(user_id)
            notices.show(`Invite sent to {names.get(user_id, rerender)}`)
        elseif mode == "gift" then
            gift_target = user_id
            table.clear(gift_selection)
        end

        mode = nil
        render()
    end

    kit.button("Go", theme.ACCENT, theme.NARROW_BUTTON, function()
        local user_id = tonumber(user_box.Text)
        if user_id and user_id > 0 and user_id % 1 == 0 and user_id ~= player.UserId then
            user_box.Text = ""
            pick(user_id)
        else
            notices.show("Type a valid user id")
        end
    end).Parent =
        remote_row
    kit.button("Close", theme.RAISED, theme.BUTTON_WIDTH, function()
        mode = nil
        render()
    end).Parent =
        picker_footer

    local function open(next_mode: Mode)
        mode = next_mode
        gift_target = nil
        render()
    end

    kit.button("Trade", theme.ACCENT, theme.BUTTON_WIDTH, function()
        open("trade")
    end).Parent = hud
    kit.button("Gift", theme.RAISED, theme.BUTTON_WIDTH, function()
        open("gift")
    end).Parent = hud

    local trade = kit.window("TradeWindow", WINDOW_WIDTH, WINDOW_HEIGHT, gui)
    kit.stack(Enum.FillDirection.Vertical).Parent = trade
    local trade_title = kit.text({
        Text = "",
        FontFace = theme.FONT_BOLD,
        TextSize = theme.TITLE_SIZE,
        Size = UDim2.new(1, 0, 0, theme.TITLE_HEIGHT),
        LayoutOrder = 1,
        Parent = trade,
    })
    local trade_status = kit.text({
        Text = "",
        TextColor3 = theme.INK_2,
        Size = UDim2.new(1, 0, 0, theme.LINE_HEIGHT),
        LayoutOrder = 2,
        Parent = trade,
    })
    local columns = create(
        "Frame",
        { Size = UDim2.new(1, 0, 0, COLUMNS_HEIGHT), BackgroundTransparency = 1, LayoutOrder = 3, Parent = trade },
        {
            create(
                "UIListLayout",
                { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, theme.EDGE) }
            ),
        }
    )

    local function side(order: number): (TextLabel, TextLabel, TextLabel, ScrollingFrame)
        local column = create("Frame", {
            Size = UDim2.new(0.5, -theme.EDGE / 2, 1, 0),
            BackgroundTransparency = 1,
            LayoutOrder = order,
            Parent = columns,
        }, { kit.stack(Enum.FillDirection.Vertical, 4) })
        local header = create("Frame", {
            Size = UDim2.new(1, 0, 0, theme.LINE_HEIGHT),
            BackgroundTransparency = 1,
            LayoutOrder = 1,
            Parent = column,
        })
        local title = kit.text({
            Text = "",
            FontFace = theme.FONT_BOLD,
            Size = UDim2.new(1, -BADGE_WIDTH, 1, 0),
            Parent = header,
        })
        local badge = kit.text({
            Text = "Accepted",
            TextColor3 = theme.GOOD,
            FontFace = theme.FONT_BOLD,
            TextSize = theme.SMALL_SIZE,
            TextXAlignment = Enum.TextXAlignment.Right,
            AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.fromScale(1, 0),
            Size = UDim2.new(0, BADGE_WIDTH, 1, 0),
            Parent = header,
        })
        local coins = kit.text({
            Text = "",
            TextColor3 = theme.INK_2,
            TextSize = theme.SMALL_SIZE,
            Size = UDim2.new(1, 0, 0, theme.CAPTION_HEIGHT),
            LayoutOrder = 2,
            Parent = column,
        })
        local offer = kit.grid(OFFER_HEIGHT, 3, column, CHIP_CELL)

        return title, badge, coins, offer
    end

    local my_title, my_badge, my_coins, my_offer = side(1)
    local their_title, their_badge, their_coins, their_offer = side(2)
    my_title.Text = "Your offer"
    kit.text({
        Text = "Your items: tap to add or remove",
        TextColor3 = theme.MUTED,
        TextSize = theme.SMALL_SIZE,
        Size = UDim2.new(1, 0, 0, theme.CAPTION_HEIGHT),
        LayoutOrder = 4,
        Parent = trade,
    })
    local trade_inventory = kit.grid(INVENTORY_HEIGHT, 5, trade, CHIP_CELL)
    local trade_footer, trade_left, trade_right = kit.footer(6, trade)
    trade_footer.Name = "Footer"
    local coins_box = kit.input("Coins", 1, trade_left)
    local set_coins = kit.button("Set coins", theme.RAISED, theme.BUTTON_WIDTH, function()
        store.offer_coins(tonumber(coins_box.Text) or 0)
    end)
    set_coins.LayoutOrder = 2
    set_coins.Parent = trade_left
    local cancel = kit.button("Cancel", theme.RAISED, theme.BUTTON_WIDTH, function()
        local view = store.active()
        if view and view.status == "negotiating" then
            store.cancel()
        else
            store.dismiss()
        end
    end)
    cancel.LayoutOrder = 1
    cancel.Parent = trade_right
    local accept = kit.button("Accept", theme.GOOD, theme.BUTTON_WIDTH, function()
        local view = store.active()
        if view and view.status == "negotiating" and not view.me.accepted then
            store.accept()
        end
    end)
    accept.LayoutOrder = 2
    accept.Parent = trade_right

    local gift = kit.window("GiftWindow", WINDOW_WIDTH, GIFT_HEIGHT, gui)
    kit.stack(Enum.FillDirection.Vertical).Parent = gift
    local gift_title = kit.text({
        Text = "",
        FontFace = theme.FONT_BOLD,
        TextSize = theme.TITLE_SIZE,
        Size = UDim2.new(1, 0, 0, theme.TITLE_HEIGHT),
        LayoutOrder = 1,
        Parent = gift,
    })
    kit.text({
        Text = "Pick items and coins. They arrive even if the player is offline.",
        TextColor3 = theme.INK_2,
        Size = UDim2.new(1, 0, 0, theme.LINE_HEIGHT),
        LayoutOrder = 2,
        Parent = gift,
    })
    local gift_inventory = kit.grid(GIFT_INVENTORY_HEIGHT, 3, gift, CHIP_CELL)
    local gift_footer, gift_left, gift_right = kit.footer(4, gift)
    gift_footer.Name = "Footer"
    local gift_coins = kit.input("Coins", 1, gift_left)
    local gift_close = kit.button("Close", theme.RAISED, theme.BUTTON_WIDTH, function()
        gift_target = nil
        render()
    end)
    gift_close.LayoutOrder = 1
    gift_close.Parent = gift_right
    local gift_send = kit.button("Send gift", theme.ACCENT, theme.WIDE_BUTTON, function()
        local target = gift_target
        if target == nil then
            return
        end

        local ids = {}
        for item_id in gift_selection do
            table.insert(ids, item_id)
        end

        local coins = tonumber(gift_coins.Text) or 0
        if #ids == 0 and coins <= 0 then
            notices.show("Pick at least one item or some coins")
            return
        end

        store.gift(target, coins, ids)
        notices.show(`Gift sent to {names.get(target, rerender)}`)
        gift_target = nil
        gift_coins.Text = ""
        render()
    end)
    gift_send.LayoutOrder = 2
    gift_send.Parent = gift_right

    local function render_roster()
        local entries: { Instance } = {}
        for _, other in players:GetPlayers() do
            if other ~= player then
                table.insert(
                    entries,
                    kit.button(other.DisplayName, theme.RAISED, PICKER_WIDTH - 2 * theme.EDGE - theme.GAP, function()
                        pick(other.UserId)
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

        kit.refill(roster, entries)
    end

    local function render_invites(state: store.State)
        local now = os.clock()
        local entries = {}
        for _, invite in state.invites do
            if now - invite.at <= tuning.trade.invite_timeout then
                local from = invite.from
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
                end).Parent =
                    actions
                kit.button("Accept", theme.GOOD, theme.NARROW_BUTTON, function()
                    store.answer(from, true)
                end).Parent =
                    actions
                table.insert(entries, row)
            end
        end

        kit.refill(toasts, entries)
    end

    local function render_trade(state: store.State, view: store.View)
        local them_id = view.them.user_id
        local them = if them_id then names.get(them_id, rerender) else "them"
        local open_trade = view.status == "negotiating"
        trade_title.Text = `Trading with {them}`
        their_title.Text = `{them}'s offer`
        my_badge.Visible = view.me.accepted
        their_badge.Visible = view.them.accepted
        my_coins.Text = `{view.me.coins} coins`
        their_coins.Text = `{view.them.coins} coins`

        local mine: { Instance } = {}
        for _, entry in sorted(view.me.items) do
            table.insert(mine, chip(entry.id, entry.kind, false, nil))
        end

        local theirs: { Instance } = {}
        for _, entry in sorted(view.them.items) do
            table.insert(theirs, chip(entry.id, entry.kind, false, nil))
        end

        local owned: { Instance } = {}
        for _, entry in sorted(state.inventory.items) do
            local item_id = entry.id
            local offered = view.me.items[item_id] ~= nil
            table.insert(
                owned,
                chip(
                    entry.id,
                    entry.kind,
                    offered,
                    if open_trade
                        then function()
                            store.offer_item(item_id, not offered)
                        end
                        else nil
                )
            )
        end

        kit.refill(my_offer, mine)
        kit.refill(their_offer, theirs)
        kit.refill(trade_inventory, owned)

        coins_box.PlaceholderText = `Coins, up to {state.inventory.coins}`
        accept.Visible = open_trade
        accept.Text = if view.me.accepted then "Accepted" else "Accept"
        accept.BackgroundColor3 = if view.me.accepted then theme.RAISED else theme.GOOD
        set_coins.Visible = open_trade
        coins_box.Visible = open_trade
        cancel.Text = if open_trade then "Cancel" else "Close"
    end

    local function render_gift(state: store.State, target: number)
        gift_title.Text = `Gift to {names.get(target, rerender)}`
        local owned: { Instance } = {}
        for _, entry in sorted(state.inventory.items) do
            local item_id = entry.id
            local selected = gift_selection[item_id] == true
            table.insert(
                owned,
                chip(entry.id, entry.kind, selected, function()
                    if selected then
                        gift_selection[item_id] = nil
                    else
                        gift_selection[item_id] = true
                    end

                    render()
                end)
            )
        end

        kit.refill(gift_inventory, owned)
        gift_coins.PlaceholderText = `Coins, up to {state.inventory.coins}`
    end

    render = function()
        local state = store.state()
        local view = store.active()
        render_invites(state)

        trade.Visible = view ~= nil
        if view then
            render_trade(state, view)
        end

        picker.Visible = view == nil and mode ~= nil
        if picker.Visible then
            picker_title.Text = if mode == "gift" then "Send a gift to" else "Trade with"
            render_roster()
        end

        local target = gift_target
        gift.Visible = view == nil and mode == nil and target ~= nil
        if target and gift.Visible then
            render_gift(state, target)
        end
    end

    local function fit()
        local camera = workspace.CurrentCamera
        if camera then
            local viewport = camera.ViewportSize
            scale.Scale =
                math.min(1, (viewport.X - 2 * theme.EDGE) / WINDOW_WIDTH, (viewport.Y - 2 * theme.EDGE) / WINDOW_HEIGHT)
        end
    end

    fit()
    if workspace.CurrentCamera then
        workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
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
        local state = store.state()
        local second = math.floor(now)
        if second ~= last_second then
            last_second = second
            render_invites(state)
        end

        local view = store.active()
        if view == nil then
            return
        end

        if
            view.status ~= "negotiating"
            and view.status ~= "locking"
            and now - state.view_at > tuning.trade.result_display
        then
            store.dismiss()
            return
        end

        local them_id = view.them.user_id
        local message, color = status_of(view, if them_id then names.get(them_id, rerender) else "them", now)
        trade_status.Text = message
        trade_status.TextColor3 = color
    end)

    render()
end

return ui
