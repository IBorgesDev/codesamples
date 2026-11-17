--!strict

local ledger = require(script.Parent.ledger)
local types = require(script.Parent.types)

type Data = types.Data
type Items = types.Items
type Outgoing = types.Outgoing

export type Message = {
    kind: "gift",
    tx_id: string,
    from: number,
    seq: number,
    coins: number,
    items: Items,
}

export type Send = (to: number, message: Message) -> boolean

local gift = {}

function gift.send(data: Data, from: number, to: number, coins: number, items: Items, now: number): (string?, string?)
    local ok, why = ledger.covers(data, coins, items)
    if not ok then
        return nil, why
    end

    local moved: Items = {}
    for item_id in items do
        moved[item_id] = data.items[item_id]
        data.items[item_id] = nil
    end

    data.gift_seq += 1
    local tx_id = `{from}:{data.gift_seq}`
    data.coins -= coins
    data.outbox[tx_id] = { to = to, from = from, seq = data.gift_seq, coins = coins, items = moved, at = now }

    return tx_id, nil
end

function gift.message(tx_id: string, outgoing: Outgoing): Message
    return {
        kind = "gift",
        tx_id = tx_id,
        from = outgoing.from,
        seq = outgoing.seq,
        coins = outgoing.coins,
        items = outgoing.items,
    }
end

function gift.pending(data: Data): { string }
    local ids = {}
    for tx_id in data.outbox do
        table.insert(ids, tx_id)
    end

    table.sort(ids, function(left, right)
        return data.outbox[left].seq < data.outbox[right].seq
    end)

    return ids
end

function gift.deliver(data: Data, ids: { string }, send: Send, active: () -> boolean): number
    local blocked: { [number]: boolean } = {}
    local delivered = 0
    for _, tx_id in ids do
        local outgoing = data.outbox[tx_id]
        if outgoing == nil or blocked[outgoing.to] then
            continue
        end

        if not active() then
            break
        end

        if send(outgoing.to, gift.message(tx_id, outgoing)) then
            data.outbox[tx_id] = nil
            delivered += 1
        else
            blocked[outgoing.to] = true
        end
    end

    return delivered
end

function gift.is_gift(message: any): boolean
    return type(message) == "table"
        and message.kind == "gift"
        and type(message.tx_id) == "string"
        and type(message.from) == "number"
        and type(message.seq) == "number"
        and message.seq % 1 == 0
        and message.seq >= 1
        and type(message.coins) == "number"
        and message.coins >= 0
        and type(message.items) == "table"
end

function gift.receive(data: Data, message: Message): boolean
    local sender = tostring(message.from)
    if message.seq <= (data.gift_seen[sender] or 0) then
        return false
    end

    for item_id, item in message.items do
        data.items[item_id] = table.clone(item)
    end

    data.coins += message.coins
    data.gift_seen[sender] = message.seq

    return true
end

return gift
