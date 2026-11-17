return function()
    local server_script_service = game:GetService("ServerScriptService")
    local deep = require(script.Parent.support.deep)
    local trade_record = require(server_script_service.Server.trade.record)

    local function side(user_id, ready)
        return { user_id = user_id, coins = 10, items = { [`i{user_id}`] = { kind = "egg_common" } }, ready = ready }
    end

    local function open()
        return deep.freeze(trade_record.new("tx", side(1, false), side(2, false), 3, 100))
    end

    describe("Record", function()
        it("is created open with the opener already voted", function()
            local record = open()
            expect(record.state).to.equal("open")
            expect(record.a.ready).to.equal(true)
            expect(record.b.ready).to.equal(false)
            expect(record.offer_version).to.equal(3)
        end)

        it("create writes only into an empty key", function()
            local transform = trade_record.create(open())
            expect(transform(nil).state).to.equal("open")
            local tombstone = deep.freeze(trade_record.abort("tx", "missing", 100)(nil))
            expect(transform(tombstone)).to.equal(nil)
        end)

        it("the second vote commits in the same write", function()
            local committed = trade_record.vote("b", 120)(open())
            expect(committed.state).to.equal("committed")
            expect(committed.decided_at).to.equal(120)
        end)

        it("a vote changes nothing on a decided, missing or already voted record", function()
            local aborted = deep.freeze(trade_record.abort("tx", "cancel", 110)(open()))
            expect(trade_record.vote("b", 120)(aborted)).to.equal(nil)
            expect(trade_record.vote("b", 120)(nil)).to.equal(nil)
            expect(trade_record.vote("a", 120)(open())).to.equal(nil)
        end)

        it("abort only moves an open record, and nothing after the commit point", function()
            local aborted = trade_record.abort("tx", "cancel", 110)(open())
            expect(aborted.state).to.equal("aborted")
            expect(aborted.reason).to.equal("cancel")
            local committed = deep.freeze(trade_record.vote("b", 120)(open()))
            expect(trade_record.abort("tx", "timeout", 130)(committed)).to.equal(nil)
        end)

        it("abort on a missing record writes a tombstone", function()
            local tombstone = trade_record.abort("tx", "missing", 100)(nil)
            expect(tombstone.state).to.equal("aborted")
            expect(tombstone.tombstone).to.equal(true)
        end)

        it("transforms never mutate the value they read (frozen input does not error)", function()
            local record = open()
            trade_record.vote("b", 120)(record)
            trade_record.abort("tx", "cancel", 110)(record)
            expect(record.b.ready).to.equal(false)
        end)
    end)
end
