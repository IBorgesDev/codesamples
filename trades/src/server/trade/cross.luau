--!strict

local coordinator = require(script.Parent.coordinator)
local negotiation = require(script.Parent.negotiation)
local protocol = require(script.Parent.protocol)
local trade_record = require(script.Parent.record)
local types = require(script.Parent.types)

type Coordinator = coordinator.Coordinator
type Shared = coordinator.Shared

local cross = {}

function cross.new(session_id: string, a_user: number, b_user: number, a_server: string, b_server: string): Shared
    return {
        session = negotiation.new(session_id, a_user, b_user),
        servers = { a = a_server, b = b_server },
        rev = 0,
        tx_id = nil,
        locked_at = nil,
        opened = nil,
        outcome = nil,
        reason = nil,
    }
end

function cross.apply(
    coord: Coordinator,
    session_id: string,
    user_id: number,
    op: negotiation.Op,
    now: number
): (boolean, Shared?, string?)
    return coord.change(session_id, function(shared)
        if shared.tx_id ~= nil then
            return false, "locked"
        end

        return negotiation.apply(shared.session, user_id, op, now)
    end)
end

function cross.record(coord: Coordinator, session_id: string, outcome: string, why: string?): boolean
    local stored = coord.change(session_id, function(shared)
        if shared.outcome ~= nil then
            return false, "recorded"
        end

        shared.outcome = outcome
        shared.reason = why

        return true, nil
    end)

    return stored
end

local function mark_opened(coord: Coordinator, session_id: string): boolean
    local stored = coord.change(session_id, function(shared)
        if shared.opened then
            return false, "opened"
        end

        shared.opened = true

        return true, nil
    end)

    return stored
end

local function side(party: negotiation.Party): types.Side
    return { user_id = party.user_id, coins = party.coins, items = party.items, ready = false }
end

local function settled(coord: Coordinator, session_id: string, outcome: string, why: string?): string
    if outcome == "open" then
        mark_opened(coord, session_id)
    elseif outcome == "committed" or outcome == "aborted" or outcome == "refused" then
        cross.record(coord, session_id, outcome, why)
    end

    return outcome
end

function cross.commit(
    coord: Coordinator,
    ports: types.Ports,
    session_id: string,
    account_a: types.Account,
    tx_id: string,
    now: number
): (string, string?)
    local locked, shared = coord.change(session_id, function(current)
        if current.tx_id ~= nil then
            return false, "locked"
        end

        if not negotiation.tick(current.session, now) then
            return false, "not_due"
        end

        current.tx_id = tx_id
        current.locked_at = now

        return true, nil
    end)

    if not locked or shared == nil then
        return "waiting", nil
    end

    local outcome, why =
        protocol.open(ports, account_a, tx_id, side(shared.session.a), side(shared.session.b), shared.session.version)

    return settled(coord, session_id, outcome, why), why
end

function cross.resume(coord: Coordinator, ports: types.Ports, shared: Shared, account: types.Account): string?
    local tx_id = shared.tx_id
    if tx_id == nil or account.data.escrow[tx_id] == nil then
        return nil
    end

    local outcome = protocol.finalize(ports, account, tx_id)
    if shared.outcome ~= nil then
        return outcome
    end

    if outcome == "open" then
        if not shared.opened then
            local ok, record = ports.records.read(tx_id)
            if ok and record ~= nil then
                mark_opened(coord, shared.session.id)
            end
        end

        return outcome
    end

    return settled(coord, shared.session.id, outcome, nil)
end

function cross.prepare(coord: Coordinator, ports: types.Ports, shared: Shared, account_b: types.Account): string?
    local tx_id = shared.tx_id
    if tx_id == nil or not shared.opened or shared.outcome ~= nil then
        return nil
    end

    local outcome, why = protocol.prepare(ports, account_b, tx_id)
    if outcome == "open" or outcome == "pending" then
        return outcome
    end

    return settled(coord, shared.session.id, outcome, why)
end

function cross.abandon(coord: Coordinator, ports: types.Ports, shared: Shared, reason: string): string?
    local tx_id = shared.tx_id
    if tx_id == nil or shared.outcome ~= nil then
        return nil
    end

    local ok, current = ports.records.update(tx_id, trade_record.abort(tx_id, reason, ports.now()))
    if not ok or current == nil then
        return "pending"
    end

    return settled(coord, shared.session.id, current.state, current.reason)
end

return cross
