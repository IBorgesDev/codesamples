--!strict

local negotiation = require(script.Parent.negotiation)
local tuning = require(script.Parent.Parent.config.tuning)

export type Status = "negotiating" | "locking" | "committed" | "aborted" | "pending"

local view = {}

local function kinds(party: negotiation.Party): { [string]: string }
    local out = {}
    for item_id, item in party.items do
        out[item_id] = item.kind
    end

    return out
end

function view.of(
    id: string,
    status: Status,
    reason: string?,
    session: negotiation.Session,
    user_id: number,
    now: number,
    shown_for: number
)
    local me = if session.a.user_id == user_id then session.a else session.b
    local them = if session.a.user_id == user_id then session.b else session.a
    local lock_at = session.lock_at
    local accept_in = math.max(negotiation.accept_in(session, user_id, now), tuning.trade.accept_delay - shown_for)

    return {
        id = id,
        status = status,
        reason = reason,
        version = session.version,
        lock_in = if lock_at then math.max(0, lock_at - now) else nil,
        accept_in = if accept_in > 0 then accept_in else nil,
        me = { coins = me.coins, items = kinds(me), accepted = me.accepted },
        them = { user_id = them.user_id, coins = them.coins, items = kinds(them), accepted = them.accepted },
    }
end

function view.status_of(outcome: string): Status
    if outcome == "committed" then
        return "committed"
    end

    if outcome == "aborted" or outcome == "refused" then
        return "aborted"
    end

    return "pending"
end

return view
