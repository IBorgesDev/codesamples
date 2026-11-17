--!strict

local counter = require(script.Parent.counter)

export type Ballot = { option: string, server: string }
export type Decision = "cast" | "change" | "same" | "foreign"

local ballot = {}

function ballot.decide(current: Ballot?, option: string, server_id: string): Decision
    if current == nil then
        return "cast"
    end

    if current.server ~= server_id then
        return "foreign"
    end

    if current.option == option then
        return "same"
    end

    return "change"
end

function ballot.count(entry: counter.Entry, previous: Ballot?, option: string)
    if previous then
        counter.retract(entry, previous.option, 1)
    end

    counter.add(entry, option, 1)
end

return ballot
