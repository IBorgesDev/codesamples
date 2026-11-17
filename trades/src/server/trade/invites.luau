--!strict

export type Book<T> = {
    offer: (target: Player, from: number, payload: T, now: number) -> boolean,
    peek: (target: Player, from: number, now: number) -> boolean,
    take: (target: Player, from: number, now: number) -> T?,
    forget: (target: Player) -> (),
}

type Invite<T> = { payload: T, at: number }

local invites = {}

function invites.book<T>(limit: number, timeout: number): Book<T>
    local pending: { [Player]: { [number]: Invite<T> } } = {}

    local function unexpired(target: Player, now: number): ({ [number]: Invite<T> }, number)
        local list = pending[target]
        if list == nil then
            list = {}
            pending[target] = list
        end

        local count = 0
        for from, invite in list do
            if now - invite.at > timeout then
                list[from] = nil
            else
                count += 1
            end
        end

        return list, count
    end

    return {
        offer = function(target, from, payload, now)
            local list, count = unexpired(target, now)
            local standing = list[from]
            if standing then
                standing.payload = payload
                return false
            end

            if count >= limit then
                return false
            end

            list[from] = { payload = payload, at = now }

            return true
        end,
        peek = function(target, from, now)
            return unexpired(target, now)[from] ~= nil
        end,
        take = function(target, from, now)
            local list = unexpired(target, now)
            local invite = list[from]
            list[from] = nil

            return if invite then invite.payload else nil
        end,
        forget = function(target)
            pending[target] = nil
        end,
    }
end

return invites
