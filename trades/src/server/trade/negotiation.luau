--!strict

local tuning = require(script.Parent.Parent.config.tuning)
local types = require(script.Parent.types)

type Item = types.Item
type Items = types.Items

export type Party = {
    user_id: number,
    coins: number,
    items: Items,
    count: number,
    accepted: boolean,
    changed_at: number?,
}

export type State = "negotiating" | "locked" | "cancelled"

export type Session = {
    id: string,
    a: Party,
    b: Party,
    version: number,
    lock_at: number?,
    state: State,
}

export type Op =
    { kind: "coins", amount: number }
    | { kind: "add", item_id: string, item: Item }
    | { kind: "remove", item_id: string }
    | { kind: "accept", version: number }
    | { kind: "cancel" }

local negotiation = {}

local function party(user_id: number): Party
    return { user_id = user_id, coins = 0, items = {}, count = 0, accepted = false }
end

function negotiation.new(id: string, a_user_id: number, b_user_id: number): Session
    assert(a_user_id ~= b_user_id, "a player cannot trade with themselves")

    return { id = id, a = party(a_user_id), b = party(b_user_id), version = 1, lock_at = nil, state = "negotiating" }
end

function negotiation.party(session: Session, user_id: number): Party?
    if session.a.user_id == user_id then
        return session.a
    end

    if session.b.user_id == user_id then
        return session.b
    end

    return nil
end

function negotiation.side(of: Party): types.Side
    return { user_id = of.user_id, coins = of.coins, items = of.items, ready = false }
end

local function is_empty(of: Party): boolean
    return of.coins == 0 and of.count == 0
end

function negotiation.accept_in(session: Session, user_id: number, now: number): number
    local them = if session.a.user_id == user_id then session.b else session.a
    local changed_at = them.changed_at
    if changed_at == nil then
        return 0
    end

    return math.max(0, changed_at + tuning.trade.accept_delay - now)
end

local function changed(session: Session, me: Party, now: number)
    me.changed_at = now
    session.version += 1
    session.a.accepted = false
    session.b.accepted = false
    session.lock_at = nil
end

function negotiation.apply(session: Session, user_id: number, op: Op, now: number): (boolean, string?)
    if session.state ~= "negotiating" then
        return false, "closed"
    end

    local me = negotiation.party(session, user_id)

    if not me then
        return false, "not_party"
    end

    if op.kind == "coins" then
        local amount = op.amount

        if amount % 1 ~= 0 or amount < 0 or amount > tuning.trade.max_coins_per_side then
            return false, "coins"
        end

        if amount == me.coins then
            return false, "unchanged"
        end

        me.coins = amount
        changed(session, me, now)
    elseif op.kind == "add" then
        if me.items[op.item_id] then
            return false, "unchanged"
        end

        if me.count >= tuning.trade.max_items_per_side then
            return false, "full"
        end

        me.items[op.item_id] = table.clone(op.item)
        me.count += 1
        changed(session, me, now)
    elseif op.kind == "remove" then
        if not me.items[op.item_id] then
            return false, "unchanged"
        end

        me.items[op.item_id] = nil
        me.count -= 1
        changed(session, me, now)
    elseif op.kind == "accept" then
        if op.version ~= session.version then
            return false, "stale"
        end

        if me.accepted then
            return false, "unchanged"
        end

        if is_empty(session.a) and is_empty(session.b) then
            return false, "empty"
        end

        if negotiation.accept_in(session, user_id, now) > 0 then
            return false, "too_soon"
        end

        me.accepted = true
        if session.a.accepted and session.b.accepted and session.lock_at == nil then
            session.lock_at = now + tuning.trade.countdown
        end
    elseif op.kind == "cancel" then
        session.state = "cancelled"
    end

    return true, nil
end

function negotiation.tick(session: Session, now: number): boolean
    local lock_at = session.lock_at

    if session.state ~= "negotiating" or lock_at == nil or now < lock_at then
        return false
    end

    session.state = "locked"

    return true
end

return negotiation
