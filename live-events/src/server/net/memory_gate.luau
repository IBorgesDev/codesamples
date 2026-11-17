--!strict

export type Gate = (fn: (...any) -> ...any, ...any) -> (boolean, ...any)

local memory_gate = {}

function memory_gate.new(base: number, cap: number, on_error: ((string) -> ())?): Gate
    local failures = 0
    local blocked_until = 0
    local random = Random.new()

    return function(fn, ...)
        if os.clock() < blocked_until then
            return false, "cooling_down"
        end

        local results = table.pack(pcall(fn, ...))
        if results[1] then
            failures = 0
        else
            if on_error then
                on_error(tostring(results[2]))
            end

            failures += 1
            local ceiling = math.min(cap, base * 2 ^ (failures - 1))
            blocked_until = os.clock() + random:NextNumber() * ceiling
        end

        return table.unpack(results, 1, results.n)
    end
end

return memory_gate
