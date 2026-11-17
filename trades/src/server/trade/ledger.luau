--!strict

local types = require(script.Parent.types)

type Data = types.Data
type Items = types.Items
type Record = types.Record
type Role = types.Role

local ledger = {}

function ledger.covers(data: Data, coins: number, items: Items): (boolean, string?)
    if data.coins < coins then
        return false, "coins"
    end

    for item_id, item in items do
        local owned = data.items[item_id]

        if not owned or owned.kind ~= item.kind then
            return false, "items"
        end
    end

    return true, nil
end

function ledger.hold(
    data: Data,
    tx_id: string,
    role: Role,
    coins: number,
    items: Items,
    now: number
): (boolean, string?)
    if data.escrow[tx_id] then
        return true, nil
    end

    local ok, why = ledger.covers(data, coins, items)

    if not ok then
        return false, why
    end

    local held: Items = {}

    for item_id in items do
        held[item_id] = data.items[item_id]
        data.items[item_id] = nil
    end

    data.coins -= coins
    data.escrow[tx_id] = { role = role, coins = coins, items = held, at = now }
    return true, nil
end

function ledger.settle(data: Data, record: Record): boolean
    local entry = data.escrow[record.tx_id]

    if not entry or record.state == "open" then
        return false
    end

    if record.state == "committed" then
        local other = if entry.role == "a" then record.b else record.a

        for item_id, item in other.items do
            data.items[item_id] = table.clone(item)
        end

        data.coins += other.coins
    else
        for item_id, item in entry.items do
            data.items[item_id] = item
        end

        data.coins += entry.coins
    end

    data.escrow[record.tx_id] = nil

    return true
end

return ledger
