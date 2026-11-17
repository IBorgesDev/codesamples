--!strict

local replicated_storage = game:GetService("ReplicatedStorage")

local chips = require(script.Parent.chips)
local kit = require(script.Parent.Parent.ui.kit)
local names = require(script.Parent.names)
local notices = require(script.Parent.Parent.ui.notices)
local store = require(script.Parent.store)
local tuning = require(replicated_storage.Shared.config.tuning)

const WIDTH = 660
const HEIGHT = 380
const INVENTORY_HEIGHT = 200
const MAX_ITEMS = tuning.trade.max_items_per_side

local theme = kit.theme

export type GiftWindow = {
    open: (target: number) -> (),
    close: () -> (),
    render: (allowed: boolean, inventory: store.Inventory) -> (),
}

local gift_window = {}

function gift_window.new(gui: Instance, rerender: () -> ()): GiftWindow
    local target: number? = nil
    local selection: { [string]: boolean } = {}

    local window = kit.window("GiftWindow", WIDTH, HEIGHT, gui)
    kit.stack(Enum.FillDirection.Vertical).Parent = window

    local title = kit.title(1, window)
    kit.text({
        Text = "Pick items and coins. They arrive even if the player is offline.",
        TextColor3 = theme.INK_2,
        Size = UDim2.new(1, 0, 0, theme.LINE_HEIGHT),
        LayoutOrder = 2,
        Parent = window,
    })
    local owned = chips.grid(INVENTORY_HEIGHT, 3, window)
    local _, left, right = kit.footer(4, window)
    local coins_box = kit.input("Coins", 1, left)

    local function open(to: number)
        target = to
        table.clear(selection)
    end

    local function close()
        target = nil
    end

    local function send()
        local to = target
        if to == nil then
            return
        end

        local item_ids = {}
        for item_id in selection do
            table.insert(item_ids, item_id)
        end

        local coins = tonumber(coins_box.Text) or 0
        if #item_ids == 0 and coins <= 0 then
            notices.show("Pick at least one item or some coins")
            return
        end

        if #item_ids > MAX_ITEMS then
            notices.show(`Pick at most {MAX_ITEMS} items`)
            return
        end

        if not store.gift(to, coins, item_ids) then
            notices.show("Could not send the gift, try again in a moment")
            return
        end

        notices.show(`Gift sent to {names.get(to, rerender)}`)
        coins_box.Text = ""
        close()
        rerender()
    end

    kit.button("Close", theme.RAISED, theme.BUTTON_WIDTH, function()
        close()
        rerender()
    end, right, 1)
    kit.button("Send gift", theme.ACCENT, theme.WIDE_BUTTON, send, right, 2)

    local function selected(item_id: string): boolean
        return selection[item_id] == true
    end

    local function toggle(item_id: string)
        if selection[item_id] then
            selection[item_id] = nil
        else
            selection[item_id] = true
        end

        rerender()
    end

    local function render(allowed: boolean, inventory: store.Inventory)
        local to = target
        window.Visible = allowed and to ~= nil
        if to == nil or not allowed then
            return
        end

        title.Text = `Gift to {names.get(to, rerender)}`
        chips.fill(owned, inventory.items, selected, toggle)
        coins_box.PlaceholderText = `Coins, up to {inventory.coins}`
    end

    return { open = open, close = close, render = render }
end

return gift_window
