--!strict

local create = require(script.Parent.create)

local theme = table.freeze({
    FONT = Font.new("rbxasset://fonts/families/BuilderSans.json"),
    FONT_BOLD = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold),
    SURFACE = Color3.fromRGB(26, 26, 25),
    RAISED = Color3.fromRGB(44, 44, 42),
    LINE = Color3.fromRGB(56, 56, 53),
    WELL = Color3.fromRGB(20, 20, 19),
    INK = Color3.fromRGB(240, 239, 236),
    INK_2 = Color3.fromRGB(195, 194, 183),
    MUTED = Color3.fromRGB(137, 135, 129),
    ACCENT = Color3.fromRGB(57, 135, 229),
    GOOD = Color3.fromRGB(12, 163, 12),
    DANGER = Color3.fromRGB(208, 59, 59),
    CORNER = UDim.new(0, 10),
    SMALL_CORNER = UDim.new(0, 8),
    GAP = 8,
    EDGE = 16,
    BUTTON_HEIGHT = 40,
    BUTTON_WIDTH = 120,
    WIDE_BUTTON = 140,
    NARROW_BUTTON = 90,
    INPUT_WIDTH = 170,
    TITLE_SIZE = 20,
    BODY_SIZE = 16,
    SMALL_SIZE = 14,
    TITLE_HEIGHT = 26,
    LINE_HEIGHT = 20,
    CAPTION_HEIGHT = 18,
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

function kit.title(order: number, parent: Instance): TextLabel
    return kit.text({
        Text = "",
        FontFace = theme.FONT_BOLD,
        TextSize = theme.TITLE_SIZE,
        Size = UDim2.new(1, 0, 0, theme.TITLE_HEIGHT),
        LayoutOrder = order,
        Parent = parent,
    })
end

function kit.caption(text: string, order: number, parent: Instance): TextLabel
    return kit.text({
        Text = text,
        TextColor3 = theme.MUTED,
        TextSize = theme.SMALL_SIZE,
        Size = UDim2.new(1, 0, 0, theme.CAPTION_HEIGHT),
        LayoutOrder = order,
        Parent = parent,
    })
end

function kit.button(
    label: string,
    color: Color3,
    width: number,
    on_click: () -> (),
    parent: Instance?,
    order: number?
): TextButton
    local instance = create("TextButton", {
        Name = label,
        Size = UDim2.fromOffset(width, theme.BUTTON_HEIGHT),
        BackgroundColor3 = color,
        AutoButtonColor = true,
        FontFace = theme.FONT_BOLD,
        Text = label,
        TextColor3 = theme.INK,
        TextSize = theme.BODY_SIZE,
        LayoutOrder = order or 0,
        Parent = parent,
    }, { kit.corner(theme.SMALL_CORNER) })
    instance.Activated:Connect(on_click)

    return instance
end

function kit.window(name: string, width: number, height: number, parent: Instance): Frame
    return create("Frame", {
        Name = name,
        Size = UDim2.fromOffset(width, height),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        BackgroundColor3 = theme.SURFACE,
        Visible = false,
        Parent = parent,
    }, { kit.corner(), kit.padding(theme.EDGE), create("UIStroke", { Color = theme.LINE, Thickness = 1 }) })
end

function kit.grid(height: number, order: number, parent: Instance, cell: UDim2): ScrollingFrame
    return create("ScrollingFrame", {
        Size = UDim2.new(1, 0, 0, height),
        BackgroundColor3 = theme.WELL,
        BorderSizePixel = 0,
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = theme.LINE,
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        CanvasSize = UDim2.new(),
        LayoutOrder = order,
        Parent = parent,
    }, {
        kit.corner(theme.SMALL_CORNER),
        kit.padding(theme.GAP),
        create("UIGridLayout", {
            CellSize = cell,
            CellPadding = UDim2.fromOffset(theme.GAP, theme.GAP),
            SortOrder = Enum.SortOrder.LayoutOrder,
        }),
    })
end

function kit.input(placeholder: string, order: number, parent: Instance): TextBox
    return create("TextBox", {
        Size = UDim2.fromOffset(theme.INPUT_WIDTH, theme.BUTTON_HEIGHT),
        BackgroundColor3 = theme.RAISED,
        FontFace = theme.FONT,
        PlaceholderText = placeholder,
        PlaceholderColor3 = theme.MUTED,
        Text = "",
        TextColor3 = theme.INK,
        TextSize = theme.BODY_SIZE,
        TextXAlignment = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false,
        LayoutOrder = order,
        Parent = parent,
    }, { kit.corner(theme.SMALL_CORNER), kit.padding(theme.GAP) })
end

function kit.footer(order: number, parent: Instance): (Frame, Frame, Frame)
    local row = create("Frame", {
        Name = "Footer",
        Size = UDim2.new(1, 0, 0, theme.BUTTON_HEIGHT),
        BackgroundTransparency = 1,
        LayoutOrder = order,
        Parent = parent,
    })
    local left = create(
        "Frame",
        { Name = "Left", Size = UDim2.fromScale(0.5, 1), BackgroundTransparency = 1, Parent = row },
        {
            kit.stack(Enum.FillDirection.Horizontal),
        }
    )
    local right = create("Frame", {
        Name = "Right",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.fromScale(1, 0),
        Size = UDim2.fromScale(0.5, 1),
        BackgroundTransparency = 1,
        Parent = row,
    }, {
        create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            HorizontalAlignment = Enum.HorizontalAlignment.Right,
            Padding = UDim.new(0, theme.GAP),
            SortOrder = Enum.SortOrder.LayoutOrder,
        }),
    })

    return row, left, right
end

function kit.refill(container: Instance, children: { Instance })
    for _, child in container:GetChildren() do
        if child:IsA("GuiObject") then
            child:Destroy()
        end
    end

    for index, child in children do
        (child :: GuiObject).LayoutOrder = index
        child.Parent = container
    end
end

return kit
