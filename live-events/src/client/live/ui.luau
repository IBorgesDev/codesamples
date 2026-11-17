--!strict

local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")

local catalog = require(replicated_storage.Shared.config.live_events)
local create = require(script.Parent.Parent.ui.create)
local kit = require(script.Parent.Parent.ui.kit)
local notices = require(script.Parent.Parent.ui.notices)
local store = require(script.Parent.store)

const PANEL_WIDTH = 300
const OPTION_HEIGHT = 36
const FIGURE_SIZE = 24
const FIGURE_HEIGHT = 28
const SHARE_TRANSPARENCY = 0.55
const PERCENT = 100
const CARD_PADDING = 12
const CARD_GAP = 6
const CARD_TRANSPARENCY = 0.05
const CAPTION_ORDER = 100
const COUNT_WIDTH = 70
const LABEL_INSET = 10

local theme = kit.theme

type Card = {
    render: () -> (),
}

local ui = {}

local function thousands(value: number): string
    local digits = tostring(math.floor(value))
    local out = string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")))

    return (string.gsub(out, "^,", ""))
end

local function card(title: string, order: number, parent: Instance): (Frame, TextLabel)
    local frame = create("Frame", {
        Name = title,
        Size = UDim2.fromOffset(PANEL_WIDTH, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = theme.SURFACE,
        BackgroundTransparency = CARD_TRANSPARENCY,
        LayoutOrder = order,
        Parent = parent,
    }, {
        kit.corner(),
        kit.padding(CARD_PADDING),
        create("UIStroke", { Color = theme.LINE, Thickness = 1 }),
        kit.stack(Enum.FillDirection.Vertical, CARD_GAP),
    })
    kit.text({
        Text = title,
        FontFace = theme.FONT_BOLD,
        Size = UDim2.new(1, 0, 0, theme.LINE_HEIGHT),
        LayoutOrder = 1,
        Parent = frame,
    })
    local caption = kit.text({
        Text = "",
        TextColor3 = theme.MUTED,
        TextSize = theme.SMALL_SIZE,
        Size = UDim2.new(1, 0, 0, theme.CAPTION_HEIGHT),
        LayoutOrder = CAPTION_ORDER,
        Parent = frame,
    })

    return frame, caption
end

local function counter_card(definition: any, order: number, parent: Instance): Card
    local frame, caption = card(definition.title, order, parent)
    local goal = definition.goal
    local option = if goal then goal.option else definition.options[1]
    kit.text({
        Text = definition.labels[option] or option,
        TextColor3 = theme.INK_2,
        TextSize = theme.SMALL_SIZE,
        Size = UDim2.new(1, 0, 0, theme.CAPTION_HEIGHT),
        LayoutOrder = 2,
        Parent = frame,
    })
    local figure = kit.text({
        Text = "0",
        FontFace = theme.FONT_BOLD,
        TextSize = FIGURE_SIZE,
        Size = UDim2.new(1, 0, 0, FIGURE_HEIGHT),
        LayoutOrder = 3,
        Parent = frame,
    })
    local fill = if goal then kit.meter(4, frame) else nil

    return {
        render = function()
            local view = store.view(definition.id)
            local value = if view then view.totals[option] or 0 else 0
            local servers = if view then view.servers else 0
            if goal == nil or fill == nil then
                figure.Text = thousands(value)
                caption.Text = `{thousands(servers)} servers online`
                return
            end

            local share = math.clamp(value / goal.target, 0, 1)
            figure.Text = `{thousands(value)} / {thousands(goal.target)}`
            fill.Size = UDim2.fromScale(share, 1)
            local reached = view ~= nil and (view.state == "completed" or value >= goal.target)
            fill.BackgroundColor3 = if reached then theme.GOOD else theme.ACCENT
            if reached then
                local coins = definition.reward_coins
                caption.Text = if coins then `Goal reached: everyone here gets {coins} coins` else "Goal reached"
                caption.TextColor3 = theme.GOOD
            else
                caption.Text = `{math.floor(share * PERCENT)}% of the goal, {thousands(servers)} servers online`
                caption.TextColor3 = theme.MUTED
            end
        end,
    }
end

local function vote_card(definition: any, order: number, parent: Instance): Card
    local frame, caption = card(definition.title, order, parent)
    local rows = {}
    for index, option in definition.options do
        local row = create("TextButton", {
            Name = option,
            Size = UDim2.new(1, 0, 0, OPTION_HEIGHT),
            BackgroundColor3 = theme.RAISED,
            AutoButtonColor = true,
            Text = "",
            LayoutOrder = 1 + index,
            Parent = frame,
        }, { kit.corner(theme.SMALL_CORNER) })
        local share = create("Frame", {
            Name = "Share",
            Size = UDim2.fromScale(0, 1),
            BackgroundColor3 = theme.ACCENT,
            BackgroundTransparency = SHARE_TRANSPARENCY,
            Parent = row,
        }, { kit.corner(theme.SMALL_CORNER) })
        local stroke = create("UIStroke", {
            Color = theme.ACCENT,
            Thickness = 2,
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
            Enabled = false,
            Parent = row,
        })
        local label = kit.text({
            Text = definition.labels[option] or option,
            Position = UDim2.fromOffset(LABEL_INSET, 0),
            Size = UDim2.new(1, -(LABEL_INSET + theme.GAP + COUNT_WIDTH), 1, 0),
            Parent = row,
        })
        local count = kit.text({
            Text = "0",
            TextColor3 = theme.INK_2,
            TextXAlignment = Enum.TextXAlignment.Right,
            AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.new(1, -theme.GAP, 0, 0),
            Size = UDim2.new(0, COUNT_WIDTH, 1, 0),
            Parent = row,
        })
        row.Activated:Connect(function()
            store.vote(definition.id, option)
        end)
        rows[option] = { share = share, stroke = stroke, label = label, count = count, row = row }
    end

    return {
        render = function()
            local view = store.view(definition.id)
            local mine = store.mine().votes[definition.id]
            local total = 0
            for _, option in definition.options do
                total += math.max(0, if view then view.totals[option] or 0 else 0)
            end

            for _, option in definition.options do
                local parts = rows[option]
                local value = math.max(0, if view then view.totals[option] or 0 else 0)
                parts.share.Size = UDim2.fromScale(if total > 0 then value / total else 0, 1)
                parts.count.Text = thousands(value)
                parts.stroke.Enabled = mine ~= nil and mine.option == option
                parts.row.AutoButtonColor = mine == nil or mine.here
            end

            if mine and not mine.here then
                caption.Text = "You voted on another server"
            elseif mine then
                caption.Text = `{thousands(total)} votes, tap to change yours`
            else
                caption.Text = `{thousands(total)} votes, tap to vote`
            end
        end,
    }
end

function ui.start()
    local gui = create("ScreenGui", {
        Name = "LiveEvents",
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        Parent = players.LocalPlayer:WaitForChild("PlayerGui"),
    })
    local panel = create("Frame", {
        Name = "Panel",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -theme.EDGE, 0, theme.EDGE),
        Size = UDim2.fromOffset(PANEL_WIDTH, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = gui,
    }, { kit.stack(Enum.FillDirection.Vertical) })

    local cards: { Card } = {}
    for index, definition in catalog do
        local built = if definition.kind == "vote"
            then vote_card(definition, index, panel)
            else counter_card(definition, index, panel)
        table.insert(cards, built)
    end

    local function render()
        for _, built in cards do
            built.render()
        end
    end

    store.on_change(render)
    store.on_reward(function(event_id)
        for _, definition in catalog do
            if definition.id == event_id then
                local coins = definition.reward_coins
                notices.show(
                    if coins
                        then `{definition.title}: goal reached, +{coins} coins`
                        else `{definition.title}: goal reached`,
                    theme.GOOD
                )
            end
        end
    end)

    render()
end

return ui
