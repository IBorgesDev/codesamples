--!strict

local create = require(script.Parent.create)

local theme = table.freeze({
    FONT = Font.new("rbxasset://fonts/families/BuilderSans.json"),
    FONT_BOLD = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold),
    SURFACE = Color3.fromRGB(26, 26, 25),
    RAISED = Color3.fromRGB(44, 44, 42),
    LINE = Color3.fromRGB(56, 56, 53),
    INK = Color3.fromRGB(240, 239, 236),
    INK_2 = Color3.fromRGB(195, 194, 183),
    MUTED = Color3.fromRGB(137, 135, 129),
    ACCENT = Color3.fromRGB(57, 135, 229),
    TRACK = Color3.fromRGB(24, 79, 149),
    GOOD = Color3.fromRGB(12, 163, 12),
    CORNER = UDim.new(0, 10),
    SMALL_CORNER = UDim.new(0, 8),
    GAP = 8,
    EDGE = 16,
    BUTTON_HEIGHT = 40,
    BODY_SIZE = 16,
    SMALL_SIZE = 14,
    LINE_HEIGHT = 20,
    CAPTION_HEIGHT = 18,
    METER_HEIGHT = 8,
})

local kit = {}

kit.theme = theme

function kit.with(base: { [string]: any }, extra: { [string]: any }): { [string]: any }
    local out = table.clone(base)
    for key, value in extra do
        out[key] = value
    end

    return out
end

function kit.corner(radius: UDim?): Instance
    return create("UICorner", { CornerRadius = radius or theme.CORNER })
end

function kit.padding(pixels: number): Instance
    local inset = UDim.new(0, pixels)

    return create("UIPadding", { PaddingTop = inset, PaddingBottom = inset, PaddingLeft = inset, PaddingRight = inset })
end

function kit.stack(direction: Enum.FillDirection, gap: number?): Instance
    return create("UIListLayout", {
        FillDirection = direction,
        Padding = UDim.new(0, gap or theme.GAP),
        SortOrder = Enum.SortOrder.LayoutOrder,
        VerticalAlignment = if direction == Enum.FillDirection.Horizontal
            then Enum.VerticalAlignment.Center
            else Enum.VerticalAlignment.Top,
    })
end

function kit.text(props: { [string]: any }): TextLabel
    return create(
        "TextLabel",
        kit.with({
            BackgroundTransparency = 1,
            FontFace = theme.FONT,
            TextColor3 = theme.INK,
            TextSize = theme.BODY_SIZE,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
        }, props)
    )
end

function kit.meter(order: number, parent: Instance): Frame
    local track = create("Frame", {
        Size = UDim2.new(1, 0, 0, theme.METER_HEIGHT),
        BackgroundColor3 = theme.TRACK,
        LayoutOrder = order,
        Parent = parent,
    }, { kit.corner(UDim.new(1, 0)) })

    return create("Frame", {
        Name = "Fill",
        Size = UDim2.fromScale(0, 1),
        BackgroundColor3 = theme.ACCENT,
        Parent = track,
    }, { kit.corner(UDim.new(1, 0)) })
end

return kit
