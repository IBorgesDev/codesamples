--!strict

local trade_record = require(script.Parent.record)
local tuning = require(script.Parent.Parent.config.tuning)
local types = require(script.Parent.types)

export type Action = "settle" | "vote" | "abort" | "wait"

local recovery = {}

function recovery.decide(entry: types.Escrow, record: types.Record?, now: number): Action
    if record == nil then
        return if now - entry.at >= tuning.trade.missing_record_grace then "abort" else "wait"
    end

    if record.state ~= "open" then
        return "settle"
    end

    if now - record.created_at >= tuning.trade.record_timeout then
        return "abort"
    end

    if not trade_record.side(record, entry.role).ready then
        return "vote"
    end

    return "wait"
end

return recovery
