--!strict

local data_store_service = game:GetService("DataStoreService")

export type Ledger = { [string]: boolean }

export type Inbox = {
    reserve: (to: number, tx_id: string) -> boolean,
    settle: (to: number, seen: { [string]: number }) -> boolean,
}

export type DataStoreLike = {
    UpdateAsync: (self: any, key: string, transform: (any) -> any) -> (any, any),
}

local inbox = {}

function inbox.key(to: number): string
    return `inbox_{to}`
end

function inbox.parse(tx_id: string): (string?, number?)
    local from, seq = string.match(tx_id, "^(%d+):(%d+)$")
    if from == nil or seq == nil then
        return nil, nil
    end

    return from, tonumber(seq)
end

function inbox.count(ledger: Ledger): number
    local count = 0
    for _ in ledger do
        count += 1
    end

    return count
end

function inbox.reserved(ledger: Ledger, tx_id: string, cap: number): (Ledger?, boolean)
    if ledger[tx_id] then
        return nil, true
    end

    if inbox.count(ledger) >= cap then
        return nil, false
    end

    local after = table.clone(ledger)
    after[tx_id] = true

    return after, true
end

function inbox.settled(ledger: Ledger, seen: { [string]: number }): Ledger?
    local after: Ledger = {}
    local changed = false
    for tx_id in ledger do
        local from, seq = inbox.parse(tx_id)
        if from ~= nil and seq ~= nil and seq <= (seen[from] or 0) then
            changed = true
        else
            after[tx_id] = true
        end
    end

    return if changed then after else nil
end

function inbox.adapter(store: DataStoreLike, cap: number): Inbox
    return {
        reserve = function(to, tx_id)
            local ok = false
            local called = pcall(function()
                store:UpdateAsync(inbox.key(to), function(current)
                    local after, fits = inbox.reserved(if type(current) == "table" then current else {}, tx_id, cap)
                    ok = fits

                    return after
                end)
            end)

            return called and ok
        end,
        settle = function(to, seen)
            return (
                pcall(function()
                    store:UpdateAsync(inbox.key(to), function(current)
                        if type(current) ~= "table" then
                            return nil
                        end

                        return inbox.settled(current, seen)
                    end)
                end)
            )
        end,
    }
end

function inbox.open(name: string, cap: number): Inbox
    return inbox.adapter(data_store_service:GetDataStore(name) :: any, cap)
end

return inbox
