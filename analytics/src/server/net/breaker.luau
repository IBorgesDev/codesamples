--!strict

type State = "closed" | "open" | "half_open"

export type Breaker = {
    allow: (self: Breaker) -> boolean,
    success: (self: Breaker) -> (),
    failure: (self: Breaker) -> (),
}

local breaker = {}

function breaker.new(failures: number, cooldown: number): Breaker
    local current: State = "closed"
    local consecutive = 0
    local opened_at = 0
    local self = {}

    function self.allow(_): boolean
        if current == "open" and os.clock() - opened_at >= cooldown then
            current = "half_open"
        end

        return current ~= "open"
    end

    function self.success(_)
        current = "closed"
        consecutive = 0
    end

    function self.failure(_)
        consecutive += 1
        if current == "half_open" or consecutive >= failures then
            current = "open"
            opened_at = os.clock()
        end
    end

    return self :: any
end

return breaker
