return function()
    local replicated_storage = game:GetService("ReplicatedStorage")
    local server_script_service = game:GetService("ServerScriptService")
    local trade_record = require(server_script_service.Server.trade.record)
    local recovery = require(server_script_service.Server.trade.recovery)
    local tuning = require(replicated_storage.Shared.config.tuning)

    const CREATED = 1000

    local function side(user_id)
        return { user_id = user_id, coins = 0, items = {}, ready = false }
    end

    local function record(state, b_ready)
        local new = trade_record.new("tx", side(1), side(2), 1, CREATED)
        new.state = state
        new.b.ready = b_ready or false

        return new
    end

    local function escrow(role, at)
        return { role = role, coins = 0, items = {}, at = at or CREATED }
    end

    const YOUNG = CREATED + 1
    const OLD = CREATED + tuning.trade.record_timeout
    const GRACE_OVER = CREATED + tuning.trade.missing_record_grace

    const CASES = {
        { "no record, escrow young", escrow("a"), nil, YOUNG, "wait" },
        { "no record, escrow old", escrow("a"), nil, GRACE_OVER, "abort" },
        { "committed", escrow("b"), record("committed"), YOUNG, "settle" },
        { "aborted", escrow("a"), record("aborted"), YOUNG, "settle" },
        { "committed and old", escrow("b"), record("committed"), OLD, "settle" },
        { "open, old", escrow("a"), record("open"), OLD, "abort" },
        { "open, own vote missing", escrow("b"), record("open"), YOUNG, "vote" },
        { "open, own vote in", escrow("a"), record("open"), YOUNG, "wait" },
        { "open, b voted, b waits for nothing new", escrow("b"), record("open", true), YOUNG, "wait" },
    }

    describe("Recovery.decide", function()
        for _, case in CASES do
            local name, entry, current, now, expected = case[1], case[2], case[3], case[4], case[5]
            it(`{name} -> {expected}`, function()
                expect(recovery.decide(entry, current, now)).to.equal(expected)
            end)
        end
    end)
end
