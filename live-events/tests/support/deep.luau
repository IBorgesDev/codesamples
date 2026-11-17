--!strict

local deep = {}

function deep.copy<T>(value: T): T
    if type(value) ~= "table" then
        return value
    end

    local out = {}

    for key, item in value :: any do
        out[key] = deep.copy(item)
    end

    return out :: any
end

function deep.equal(a: any, b: any): boolean
    if type(a) ~= "table" or type(b) ~= "table" then
        return a == b
    end

    for key, item in a do
        if not deep.equal(item, b[key]) then
            return false
        end
    end

    for key in b do
        if a[key] == nil then
            return false
        end
    end

    return true
end

function deep.freeze<T>(value: T): T
    if type(value) == "table" then
        for _, item in value :: any do
            deep.freeze(item)
        end

        if not table.isfrozen(value :: any) then
            table.freeze(value :: any)
        end
    end

    return value
end

return deep
