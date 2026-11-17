--!strict

local data_store_service = game:GetService("DataStoreService")

local types = require(script.Parent.types)

type Snapshot = types.Snapshot

export type Store = {
    write: (event_id: string, kind: types.Kind, snapshot: Snapshot) -> boolean,
    read: (event_id: string) -> (boolean, Snapshot?),
}

local archive = {}

local function earliest(a: number?, b: number?): number?
    if a == nil then
        return b
    end

    if b == nil then
        return a
    end

    return math.min(a, b)
end

function archive.merge(kind: types.Kind, current: Snapshot?, incoming: Snapshot): Snapshot?
    if current == nil then
        return incoming
    end

    if kind == "vote" then
        return if incoming.at > current.at then incoming else nil
    end

    local totals = table.clone(current.totals)
    local grew = false
    for option, value in incoming.totals do
        if value > (totals[option] or 0) then
            totals[option] = value
            grew = true
        end
    end

    local completed_at = earliest(current.completed_at, incoming.completed_at)
    local closed = current.state == "closed" or incoming.state == "closed"
    if not grew and completed_at == current.completed_at and closed == (current.state == "closed") then
        return nil
    end

    local merged = table.clone(incoming)
    merged.totals = totals
    merged.completed_at = completed_at
    merged.state = if closed then "closed" elseif completed_at then "completed" else incoming.state
    merged.at = math.max(current.at, incoming.at)

    return merged
end

function archive.floor(kind: types.Kind, archived: Snapshot?): types.Tally
    if kind ~= "counter" or archived == nil then
        return {}
    end

    return table.clone(archived.totals)
end

function archive.open(name: string): Store
    local store = data_store_service:GetDataStore(name)

    return {
        write = function(event_id, kind, snapshot)
            local ok = pcall(function()
                store:UpdateAsync(event_id, function(current: Snapshot?): Snapshot?
                    return archive.merge(kind, current, snapshot)
                end)
            end)

            return ok
        end,
        read = function(event_id)
            local ok, value = pcall(function()
                return store:GetAsync(event_id)
            end)

            return ok, if ok then value else nil
        end,
    }
end

return archive
