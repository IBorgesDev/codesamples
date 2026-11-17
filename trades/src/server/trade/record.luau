--!strict

local types = require(script.Parent.types)

type Items = types.Items
type Record = types.Record
type Role = types.Role
type Side = types.Side
type Transform = (current: Record?) -> Record?

local trade_record = {}

local function copy_items(items: Items): Items
    local out: Items = {}

    for item_id, item in items do
        out[item_id] = table.clone(item)
    end

    return out
end

local function copy_side(side: Side): Side
    return { user_id = side.user_id, coins = side.coins, items = copy_items(side.items), ready = side.ready }
end

local function copy(record: Record): Record
    local out = table.clone(record)
    out.a = copy_side(record.a)
    out.b = copy_side(record.b)

    return out
end

function trade_record.side(record: Record, role: Role): Side
    return if role == "a" then record.a else record.b
end

function trade_record.role_of(record: Record, user_id: number): Role?
    if record.a.user_id == user_id then
        return "a"
    end

    if record.b.user_id == user_id then
        return "b"
    end

    return nil
end

function trade_record.new(tx_id: string, a: Side, b: Side, offer_version: number, now: number): Record
    local record: Record = {
        tx_id = tx_id,
        state = "open",
        a = copy_side(a),
        b = copy_side(b),
        offer_version = offer_version,
        created_at = now,
    }

    record.a.ready = true
    record.b.ready = false

    return record
end

function trade_record.create(record: Record): Transform
    return function(current)
        if current ~= nil then
            return nil
        end

        return copy(record)
    end
end

function trade_record.vote(role: Role, now: number): Transform
    return function(current)
        if current == nil or current.state ~= "open" or trade_record.side(current, role).ready then
            return nil
        end

        local new = copy(current)
        trade_record.side(new, role).ready = true
        if new.a.ready and new.b.ready then
            new.state = "committed"
            new.decided_at = now
        end

        return new
    end
end

local function empty_side(): Side
    return { user_id = 0, coins = 0, items = {}, ready = false }
end

function trade_record.abort(tx_id: string, reason: string, now: number): Transform
    return function(current)
        if current == nil then
            return {
                tx_id = tx_id,
                state = "aborted",
                a = empty_side(),
                b = empty_side(),
                offer_version = 0,
                created_at = now,
                decided_at = now,
                reason = reason,
                tombstone = true,
            }
        end

        if current.state ~= "open" then
            return nil
        end

        local new = copy(current)
        new.state = "aborted"
        new.decided_at = now
        new.reason = reason

        return new
    end
end

return trade_record
