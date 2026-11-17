--!strict

local counter = require(script.Parent.counter)
local types = require(script.Parent.types)

export type Ballot = types.Ballot

export type Decision = "cast" | "change" | "same" | "locked"

local ballot = {}

function ballot.decide(current: Ballot?, option: string): Decision
    if current == nil then
        return "cast"
    end

    if current.plus == nil then
        return "locked"
    end

    if current.option == option then
        return "same"
    end

    return "change"
end

function ballot.next(current: Ballot?, option: string): Ballot
    local plus = if current and current.plus then table.clone(current.plus) else {}
    local minus = if current and current.minus then table.clone(current.minus) else {}
    plus[option] = (plus[option] or 0) + 1
    if current then
        minus[current.option] = (minus[current.option] or 0) + 1
    end

    return { option = option, plus = plus, minus = minus }
end

function ballot.entry(cast: Ballot): counter.Entry
    return {
        plus = if cast.plus then table.clone(cast.plus) else {},
        minus = if cast.minus then table.clone(cast.minus) else {},
    }
end

function ballot.same(a: Ballot?, b: Ballot?): boolean
    if a == nil or b == nil or a.option ~= b.option or a.plus == nil or b.plus == nil then
        return false
    end

    return counter.dominates(ballot.entry(a), ballot.entry(b)) and counter.dominates(ballot.entry(b), ballot.entry(a))
end

return ballot
