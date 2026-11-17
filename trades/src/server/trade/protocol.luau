--!strict

local ledger = require(script.Parent.ledger)
local recovery = require(script.Parent.recovery)
local trade_record = require(script.Parent.record)
local types = require(script.Parent.types)

type Account = types.Account
type Data = types.Data
type Outcome = types.Outcome
type Ports = types.Ports
type Role = types.Role
type Side = types.Side

local protocol = {}

local function escrow_saved(tx_id: string): (Data) -> boolean
    return function(saved)
        return saved.escrow[tx_id] ~= nil
    end
end

local function escrow_gone(tx_id: string): (Data) -> boolean
    return function(saved)
        return saved.escrow[tx_id] == nil
    end
end

local function settle(ports: Ports, account: Account, record: types.Record): Outcome
    if account.active() and ledger.settle(account.data, record) then
        ports.later(function()
            account.persist(escrow_gone(record.tx_id))
        end)
    end

    return record.state
end

local function abort(ports: Ports, account: Account, tx_id: string, reason: string): Outcome
    local ok, current = ports.records.update(tx_id, trade_record.abort(tx_id, reason, ports.now()))

    if not ok then
        return "pending"
    end

    return settle(ports, account, current)
end

local function vote(ports: Ports, account: Account, tx_id: string, role: Role): Outcome
    local ok, current = ports.records.update(tx_id, trade_record.vote(role, ports.now()))

    if not ok or current == nil then
        return "pending"
    end

    if current.state == "open" then
        return "open"
    end

    return settle(ports, account, current)
end

function protocol.open(
    ports: Ports,
    account: Account,
    tx_id: string,
    a: Side,
    b: Side,
    offer_version: number
): (Outcome, string?)
    if not account.active() then
        return "refused", "inactive"
    end

    local held, why = ledger.hold(account.data, tx_id, "a", a.coins, a.items, ports.now())

    if not held then
        return "refused", why
    end

    if not account.persist(escrow_saved(tx_id)) then
        return abort(ports, account, tx_id, "a_unsaved"), "a_unsaved"
    end

    local record = trade_record.new(tx_id, a, b, offer_version, ports.now())
    local ok, current = ports.records.update(tx_id, trade_record.create(record))

    if not ok then
        return "pending", nil
    end

    if current.state == "open" then
        return "open", nil
    end

    return settle(ports, account, current), current.reason
end

function protocol.prepare(ports: Ports, account: Account, tx_id: string): (Outcome, string?)
    local ok, record = ports.records.read(tx_id)

    if not ok then
        return "pending", nil
    end

    if record == nil then
        return "refused", "missing"
    end

    if record.state ~= "open" then
        return settle(ports, account, record), record.reason
    end

    if trade_record.role_of(record, account.user_id) ~= "b" then
        return "refused", "not_party"
    end

    if not account.active() then
        return abort(ports, account, tx_id, "b_left"), "b_left"
    end

    local side = record.b
    local held, why = ledger.hold(account.data, tx_id, "b", side.coins, side.items, ports.now())

    if not held then
        local reason = `b_{why}`
        return abort(ports, account, tx_id, reason), reason
    end

    if not account.persist(escrow_saved(tx_id)) then
        return abort(ports, account, tx_id, "b_unsaved"), "b_unsaved"
    end

    return vote(ports, account, tx_id, "b"), nil
end

function protocol.finalize(ports: Ports, account: Account, tx_id: string): Outcome
    local entry = account.data.escrow[tx_id]

    if not entry or not account.active() then
        return "refused"
    end

    local ok, record = ports.records.read(tx_id)

    if not ok then
        return "pending"
    end

    local action = recovery.decide(entry, record, ports.now())

    if action == "settle" then
        return settle(ports, account, record)
    end

    if action == "abort" then
        return abort(ports, account, tx_id, if record then "timeout" else "missing")
    end

    if action == "vote" then
        if not account.persist(escrow_saved(tx_id)) then
            return "pending"
        end

        return vote(ports, account, tx_id, entry.role)
    end

    return "open"
end

function protocol.decided(outcome: string?): boolean
    return outcome == "committed" or outcome == "aborted" or outcome == "refused"
end

function protocol.run(
    ports: Ports,
    a: Account,
    b: Account,
    tx_id: string,
    a_side: Side,
    b_side: Side,
    offer_version: number
): (Outcome, string?)
    local opened: Outcome, why: string? = protocol.open(ports, a, tx_id, a_side, b_side, offer_version)
    if opened == "open" then
        opened, why = protocol.prepare(ports, b, tx_id)
        if protocol.decided(opened) then
            protocol.finalize(ports, a, tx_id)
        end
    end

    return opened, why
end

function protocol.recover(ports: Ports, account: Account)
    for tx_id in table.clone(account.data.escrow) do
        if not account.active() then
            return
        end

        protocol.finalize(ports, account, tx_id)
    end
end

return protocol
