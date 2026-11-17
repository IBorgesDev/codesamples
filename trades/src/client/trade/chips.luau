--!strict

local replicated_storage = game:GetService("ReplicatedStorage")

local create = require(script.Parent.Parent.ui.create)
local item_kinds = require(replicated_storage.Shared.config.items)
local kit = require(script.Parent.Parent.ui.kit)

const RARITY = {
    Color3.fromRGB(137, 135, 129),
    Color3.fromRGB(25, 158, 112),
    Color3.fromRGB(144, 133, 233),
    Color3.fromRGB(217, 89, 38),
}
const CELL = UDim2.fromOffset(112, 48)
const TEXT_SIZE = 15
const RARITY_BAR = 4
const SELECTED_STROKE = 2

local theme = kit.theme

type Entry = { id: string, kind: string }

local chips = {}

local function rarity_of(kind: string): number
    local definition = item_kinds[kind]

    return if definition then definition.rarity else 0
end

local function sorted(items: { [string]: string }): { Entry }
    local out: { Entry } = {}
    for item_id, kind in items do
        table.insert(out, { id = item_id, kind = kind })
    end

    table.sort(out, function(a, b)
        local rarity_a, rarity_b = rarity_of(a.kind), rarity_of(b.kind)
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

local function chip(entry: Entry, selected: boolean, on_click: (() -> ())?): GuiObject
    local definition = item_kinds[entry.kind]
    local children = {
        kit.corner(theme.SMALL_CORNER),
        create("UIStroke", {
            Color = theme.ACCENT,
            Thickness = SELECTED_STROKE,
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
            Enabled = selected,
        }),
        create("Frame", {
            Size = UDim2.new(0, RARITY_BAR, 1, -2 * theme.GAP),
            Position = UDim2.fromOffset(theme.GAP, theme.GAP),
            BackgroundColor3 = RARITY[rarity_of(entry.kind)] or RARITY[1],
            BorderSizePixel = 0,
        }, { kit.corner(UDim.new(0, RARITY_BAR / 2)) }),
        kit.text({
            Text = if definition then definition.name else entry.kind,
            Position = UDim2.fromOffset(2 * theme.GAP + RARITY_BAR, 0),
            Size = UDim2.new(1, -(3 * theme.GAP + RARITY_BAR), 1, 0),
            TextSize = TEXT_SIZE,
        }),
    }

    if on_click == nil then
        return create("Frame", { Name = entry.id, BackgroundColor3 = theme.RAISED }, children)
    end

    local button = create(
        "TextButton",
        { Name = entry.id, BackgroundColor3 = theme.RAISED, AutoButtonColor = true, Text = "" },
        children
    )
    button.Activated:Connect(on_click)

    return button
end

function chips.grid(height: number, order: number, parent: Instance): ScrollingFrame
    return kit.grid(height, order, parent, CELL)
end

function chips.fill(
    grid: ScrollingFrame,
    items: { [string]: string },
    selected: ((item_id: string) -> boolean)?,
    on_click: ((item_id: string) -> ())?
)
    local children: { Instance } = {}
    for _, entry in sorted(items) do
        local item_id = entry.id
        local click = if on_click
            then function()
                on_click(item_id)
            end
            else nil

        table.insert(children, chip(entry, selected ~= nil and selected(item_id), click))
    end

    kit.refill(grid, children)
end

return chips
