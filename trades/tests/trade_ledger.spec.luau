return function()
    local server_script_service = game:GetService("ServerScriptService")
    local deep = require(script.Parent.support.deep)
    local ledger = require(server_script_service.Server.trade.ledger)
    local trade_record = require(server_script_service.Server.trade.record)

    local function data()
        return {
            coins = 100,
            items = { i1 = { kind = "egg_common" }, i2 = { kind = "pet_cat" } },
            escrow = {},
            gift_seq = 0,
            gift_seen = {},
            outbox = {},
        }
    end

    local function record(state)
        local new = trade_record.new(
            "tx",
            { user_id = 1, coins = 30, items = { i1 = { kind = "egg_common" } }, ready = false },
            { user_id = 2, coins = 5, items = { j9 = { kind = "pet_dragon" } }, ready = false },
            1,
            100
        )
        new.state = state

        return deep.freeze(new)
    end

    describe("Ledger", function()
        it("hold moves the offer from the inventory into escrow", function()
            local d = data()
            local ok = ledger.hold(d, "tx", "a", 30, { i1 = { kind = "egg_common" } }, 100)
            expect(ok).to.equal(true)
            expect(d.coins).to.equal(70)
            expect(d.items.i1).to.equal(nil)
            expect(d.escrow.tx.items.i1.kind).to.equal("egg_common")
            expect(d.escrow.tx.coins).to.equal(30)
        end)

        it("hold twice for the same trade changes nothing the second time", function()
            local d = data()
            ledger.hold(d, "tx", "a", 30, { i1 = { kind = "egg_common" } }, 100)
            local snapshot = deep.copy(d)
            expect(ledger.hold(d, "tx", "a", 30, { i1 = { kind = "egg_common" } }, 100)).to.equal(true)
            expect(deep.equal(d, snapshot)).to.equal(true)
        end)

        it("hold refuses what the player does not have and leaves data untouched", function()
            local d = data()
            local snapshot = deep.copy(d)
            local ok, why = ledger.hold(d, "tx", "a", 500, {}, 100)
            expect(ok).to.equal(false)
            expect(why).to.equal("coins")
            ok, why = ledger.hold(d, "tx", "a", 0, { nope = { kind = "egg_common" } }, 100)
            expect(why).to.equal("items")
            ok, why = ledger.hold(d, "tx", "a", 0, { i1 = { kind = "pet_dragon" } }, 100)
            expect(why).to.equal("items")
            expect(deep.equal(d, snapshot)).to.equal(true)
        end)

        it("an item held for one trade cannot be held for another", function()
            local d = data()
            ledger.hold(d, "tx", "a", 0, { i1 = { kind = "egg_common" } }, 100)
            expect((ledger.hold(d, "tx2", "a", 0, { i1 = { kind = "egg_common" } }, 100))).to.equal(false)
        end)

        it("settle on committed credits the other side and drops the escrow", function()
            local d = data()
            ledger.hold(d, "tx", "a", 30, { i1 = { kind = "egg_common" } }, 100)
            expect(ledger.settle(d, record("committed"))).to.equal(true)
            expect(d.escrow.tx).to.equal(nil)
            expect(d.items.i1).to.equal(nil)
            expect(d.items.j9.kind).to.equal("pet_dragon")
            expect(d.coins).to.equal(75)
        end)

        it("settle on aborted gives back what was held", function()
            local d = data()
            local before = deep.copy(d)
            ledger.hold(d, "tx", "a", 30, { i1 = { kind = "egg_common" } }, 100)
            expect(ledger.settle(d, record("aborted"))).to.equal(true)
            expect(deep.equal(d, before)).to.equal(true)
        end)

        it("settle is idempotent and waits while the record is open", function()
            local d = data()
            ledger.hold(d, "tx", "a", 30, { i1 = { kind = "egg_common" } }, 100)
            expect(ledger.settle(d, record("open"))).to.equal(false)
            expect(d.escrow.tx).to.be.ok()
            ledger.settle(d, record("committed"))
            local once = deep.copy(d)
            expect(ledger.settle(d, record("committed"))).to.equal(false)
            expect(ledger.settle(d, record("aborted"))).to.equal(false)
            expect(deep.equal(d, once)).to.equal(true)
        end)
    end)
end
