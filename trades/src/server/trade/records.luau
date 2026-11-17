--!strict

local data_store_service = game:GetService("DataStoreService")

local types = require(script.Parent.types)

export type DataStoreLike = {
    UpdateAsync: (self: any, key: string, transform: (any) -> any) -> (any, any),
    GetAsync: (self: any, key: string, options: any?) -> (any, any),
}

export type Counted = types.RecordStore & { calls: () -> number }

local records = {}

function records.adapter(store: DataStoreLike, fresh: any?): Counted
    local calls = 0

    return {
        update = function(tx_id, transform)
            calls += 1
            local seen = nil
            local ok, result = pcall(function()
                return store:UpdateAsync(tx_id, function(current)
                    seen = current
                    return transform(current)
                end)
            end)

            if not ok then
                return false, result
            end

            if result == nil then
                return true, seen
            end

            return true, result
        end,
        read = function(tx_id)
            calls += 1
            return pcall(function()
                return (store:GetAsync(tx_id, fresh))
            end)
        end,
        calls = function()
            return calls
        end,
    }
end

function records.open(name: string): Counted
    local fresh = Instance.new("DataStoreGetOptions")
    fresh.UseCache = false

    return records.adapter(data_store_service:GetDataStore(name) :: any, fresh)
end

function records.budget(): number
    return data_store_service:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
end

return records
