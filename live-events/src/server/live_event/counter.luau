--!strict

export type Tally = { [string]: number }

export type Entry = {
    plus: Tally,
    minus: Tally,
    seen: number?,
}

export type Shard = { [string]: Entry }

export type Transform = (current: Shard?) -> Shard?

local counter = {}

function counter.entry(): Entry
    return { plus = {}, minus = {} }
end

function counter.copy(entry: Entry): Entry
    return { plus = table.clone(entry.plus), minus = table.clone(entry.minus), seen = entry.seen }
end

function counter.add(entry: Entry, option: string, amount: number)
    entry.plus[option] = (entry.plus[option] or 0) + amount
end

function counter.retract(entry: Entry, option: string, amount: number)
    entry.minus[option] = (entry.minus[option] or 0) + amount
end

local function covers(a: Tally, b: Tally): boolean
    for option, value in b do
        if value > (a[option] or 0) then
            return false
        end
    end

    return true
end

function counter.dominates(a: Entry, b: Entry): boolean
    return covers(a.plus, b.plus) and covers(a.minus, b.minus) and (a.seen or 0) >= (b.seen or 0)
end

local function merge_tally(into: Tally, from: Tally)
    for option, value in from do
        if value > (into[option] or 0) then
            into[option] = value
        end
    end
end

function counter.merge(a: Entry, b: Entry): Entry
    local merged = counter.copy(a)
    merge_tally(merged.plus, b.plus)
    merge_tally(merged.minus, b.minus)
    merged.seen = math.max(a.seen or 0, b.seen or 0)

    return merged
end

function counter.publish(server_id: string, entry: Entry): Transform
    return function(current)
        local stored = if current then current[server_id] else nil
        if stored and counter.dominates(stored, entry) then
            return nil
        end

        local shard: Shard = if current then table.clone(current) else {}
        shard[server_id] = if stored then counter.merge(stored, entry) else counter.copy(entry)

        return shard
    end
end

function counter.value(entry: Entry): Tally
    local totals: Tally = {}
    for option, value in entry.plus do
        totals[option] = (totals[option] or 0) + value
    end

    for option, value in entry.minus do
        totals[option] = (totals[option] or 0) - value
    end

    return totals
end

function counter.sum(into: Tally, tally: Tally)
    for option, value in tally do
        into[option] = (into[option] or 0) + value
    end
end

function counter.totals(shards: { [any]: Shard }, since: number?): (Tally, number, number)
    local totals: Tally = {}
    local servers = 0
    local live = 0
    for _, shard in shards do
        for _, entry in shard do
            servers += 1
            if since == nil or (entry.seen or 0) >= since then
                live += 1
            end

            counter.sum(totals, counter.value(entry))
        end
    end

    return totals, servers, live
end

return counter
