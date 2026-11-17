--!strict

local replicated_storage = game:GetService("ReplicatedStorage")

local chips = require(script.Parent.chips)
local create = require(script.Parent.Parent.ui.create)
local kit = require(script.Parent.Parent.ui.kit)
local names = require(script.Parent.names)
local store = require(script.Parent.store)
local tuning = require(replicated_storage.Shared.config.tuning)

const SIZE = Vector2.new(660, 500)
const COLUMNS_HEIGHT = 170
const OFFER_HEIGHT = 118
const INVENTORY_HEIGHT = 150
const BADGE_WIDTH = 90
const COLUMN_GAP = 4
const REASONS: { [string]: string } = {
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

type Column = {
    title: TextLabel,
    badge: TextLabel,
    coins: TextLabel,
    offer: ScrollingFrame,
}

export type TradeWindow = {
    render: (view: store.View?, inventory: store.Inventory) -> (),
    tick: (now: number) -> (),
}

local trade_window = {}

trade_window.SIZE = SIZE

local function accept_label(view: store.View): string
    if view.me.accepted then
        return "Accepted"
    end

    local wait = store.accept_in()
    if wait > 0 then
        return `Accept ({math.ceil(wait)})`
    end

    return "Accept"
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
        local why = if reason then REASONS[reason] or reason else REASONS.cancelled
        return `Trade cancelled: {why}`, theme.DANGER
    end

    return "Finishing in the background, nothing is lost", theme.INK_2
end

local function column(order: number, parent: Instance): Column
    local frame = create("Frame", {
        Size = UDim2.new(0.5, -theme.EDGE / 2, 1, 0),
        BackgroundTransparency = 1,
        LayoutOrder = order,
        Parent = parent,
    }, { kit.stack(Enum.FillDirection.Vertical, COLUMN_GAP) })
    local header = create("Frame", {
        Size = UDim2.new(1, 0, 0, theme.LINE_HEIGHT),
        BackgroundTransparency = 1,
        LayoutOrder = 1,
        Parent = frame,
    })

    return {
        title = kit.text({
            Text = "",
            FontFace = theme.FONT_BOLD,
            Size = UDim2.new(1, -BADGE_WIDTH, 1, 0),
            Parent = header,
        }),
        badge = kit.text({
            Text = "Accepted",
            TextColor3 = theme.GOOD,
            FontFace = theme.FONT_BOLD,
            TextSize = theme.SMALL_SIZE,
            TextXAlignment = Enum.TextXAlignment.Right,
            AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.fromScale(1, 0),
            Size = UDim2.new(0, BADGE_WIDTH, 1, 0),
            Parent = header,
        }),
        coins = kit.text({
            Text = "",
            TextColor3 = theme.INK_2,
            TextSize = theme.SMALL_SIZE,
            Size = UDim2.new(1, 0, 0, theme.CAPTION_HEIGHT),
            LayoutOrder = 2,
            Parent = frame,
        }),
        offer = chips.grid(OFFER_HEIGHT, 3, frame),
    }
end

local function show_side(shown: Column, side: store.Side)
    shown.badge.Visible = side.accepted
    shown.coins.Text = `{side.coins} coins`
    chips.fill(shown.offer, side.items)
end

function trade_window.new(gui: Instance, rerender: () -> ()): TradeWindow
    local window = kit.window("TradeWindow", SIZE.X, SIZE.Y, gui)
    kit.stack(Enum.FillDirection.Vertical).Parent = window

    local title = kit.title(1, window)
    local status = kit.text({
        Text = "",
        TextColor3 = theme.INK_2,
        Size = UDim2.new(1, 0, 0, theme.LINE_HEIGHT),
        LayoutOrder = 2,
        Parent = window,
    })
    local columns = create(
        "Frame",
        { Size = UDim2.new(1, 0, 0, COLUMNS_HEIGHT), BackgroundTransparency = 1, LayoutOrder = 3, Parent = window },
        {
            create("UIListLayout", {
                FillDirection = Enum.FillDirection.Horizontal,
                Padding = UDim.new(0, theme.EDGE),
                SortOrder = Enum.SortOrder.LayoutOrder,
            }),
        }
    )
    local mine = column(1, columns)
    local theirs = column(2, columns)
    mine.title.Text = "Your offer"

    kit.caption("Your items: tap to add or remove", 4, window)
    local owned = chips.grid(INVENTORY_HEIGHT, 5, window)

    local _, left, right = kit.footer(6, window)
    local coins_box = kit.input("Coins", 1, left)
    local set_coins = kit.button("Set coins", theme.RAISED, theme.BUTTON_WIDTH, function()
        store.offer_coins(tonumber(coins_box.Text) or 0)
    end, left, 2)
    local cancel = kit.button("Cancel", theme.RAISED, theme.BUTTON_WIDTH, function()
        local view = store.active()
        if view and view.status == "negotiating" then
            store.cancel()
        else
            store.dismiss()
        end
    end, right, 1)
    local accept = kit.button("Accept", theme.GOOD, theme.BUTTON_WIDTH, function()
        local view = store.active()
        if view and view.status == "negotiating" and not view.me.accepted then
            store.accept()
        end
    end, right, 2)

    local function partner(view: store.View): string
        local them_id = view.them.user_id

        return if them_id then names.get(them_id, rerender) else "them"
    end

    local function render(view: store.View?, inventory: store.Inventory)
        window.Visible = view ~= nil
        if view == nil then
            return
        end

        local them = partner(view)
        local negotiating = view.status == "negotiating"
        title.Text = `Trading with {them}`
        theirs.title.Text = `{them}'s offer`
        show_side(mine, view.me)
        show_side(theirs, view.them)

        local function offered(item_id: string): boolean
            return view.me.items[item_id] ~= nil
        end

        local function toggle(item_id: string)
            store.offer_item(item_id, not offered(item_id))
        end

        chips.fill(owned, inventory.items, offered, if negotiating then toggle else nil)

        coins_box.PlaceholderText = `Coins, up to {inventory.coins}`
        coins_box.Visible = negotiating
        set_coins.Visible = negotiating
        accept.Visible = negotiating
        accept.Text = accept_label(view)
        accept.BackgroundColor3 = if view.me.accepted then theme.RAISED else theme.GOOD
        cancel.Text = if negotiating then "Cancel" else "Close"
    end

    local function tick(now: number)
        local view = store.active()
        if view == nil then
            return
        end

        local decided = view.status ~= "negotiating" and view.status ~= "locking"
        if decided and now - store.state().view_at > tuning.trade.result_display then
            store.dismiss()
            return
        end

        local message, color = status_of(view, partner(view), now)
        status.Text = message
        status.TextColor3 = color
        accept.Text = accept_label(view)
    end

    return { render = render, tick = tick }
end

return trade_window
