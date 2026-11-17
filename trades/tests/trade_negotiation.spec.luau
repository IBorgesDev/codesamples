return function()
    local replicated_storage = game:GetService("ReplicatedStorage")
    local server_script_service = game:GetService("ServerScriptService")
    local negotiation = require(server_script_service.Server.trade.negotiation)
    local tuning = require(replicated_storage.Shared.config.tuning)

    const A = 1
    const B = 2
    const EGG = { kind = "egg_common" }

    local function both(session, now)
        negotiation.apply(session, A, { kind = "accept", version = session.version }, now)
        negotiation.apply(session, B, { kind = "accept", version = session.version }, now)
    end

    describe("Negotiation", function()
        it("any change to an offer bumps the version and clears both accepts", function()
            local session = negotiation.new("s", A, B)
            negotiation.apply(session, A, { kind = "accept", version = 1 }, 0)
            expect(session.a.accepted).to.equal(true)
            negotiation.apply(session, B, { kind = "add", item_id = "j1", item = EGG }, 0)
            expect(session.version).to.equal(2)
            expect(session.a.accepted).to.equal(false)
        end)

        it("refuses an accept for a version the player did not see", function()
            local session = negotiation.new("s", A, B)
            negotiation.apply(session, B, { kind = "coins", amount = 50 }, 0)
            local ok, why = negotiation.apply(session, A, { kind = "accept", version = 1 }, 0)
            expect(ok).to.equal(false)
            expect(why).to.equal("stale")
        end)

        it("locks after the countdown when both accepted the same version", function()
            local session = negotiation.new("s", A, B)
            both(session, 10)
            expect(negotiation.tick(session, 10 + tuning.trade.countdown - 0.1)).to.equal(false)
            expect(negotiation.tick(session, 10 + tuning.trade.countdown)).to.equal(true)
            expect(session.state).to.equal("locked")
            expect((negotiation.apply(session, A, { kind = "coins", amount = 1 }, 20))).to.equal(false)
        end)

        it("a change during the countdown cancels it (bait-and-switch)", function()
            local session = negotiation.new("s", A, B)
            negotiation.apply(session, B, { kind = "add", item_id = "j1", item = EGG }, 0)
            both(session, 10)
            negotiation.apply(session, B, { kind = "remove", item_id = "j1" }, 11)
            expect(session.lock_at).to.equal(nil)
            expect(negotiation.tick(session, 100)).to.equal(false)
        end)

        it("spamming accept does not push the countdown", function()
            local session = negotiation.new("s", A, B)
            both(session, 10)
            local lock_at = session.lock_at
            negotiation.apply(session, A, { kind = "accept", version = session.version }, 12)
            expect(session.lock_at).to.equal(lock_at)
        end)

        it("a no-op change keeps the version", function()
            local session = negotiation.new("s", A, B)
            negotiation.apply(session, A, { kind = "remove", item_id = "nothing" }, 0)
            negotiation.apply(session, A, { kind = "coins", amount = 0 }, 0)
            expect(session.version).to.equal(1)
        end)

        it("validates coins and the item limit", function()
            local session = negotiation.new("s", A, B)

            for _, amount in { -1, 1.5, 0 / 0, math.huge, tuning.trade.max_coins_per_side + 1 } do
                expect((negotiation.apply(session, A, { kind = "coins", amount = amount }, 0))).to.equal(false)
            end

            for n = 1, tuning.trade.max_items_per_side do
                negotiation.apply(session, A, { kind = "add", item_id = `i{n}`, item = EGG }, 0)
            end

            local ok, why = negotiation.apply(session, A, { kind = "add", item_id = "extra", item = EGG }, 0)
            expect(ok).to.equal(false)
            expect(why).to.equal("full")
        end)

        it("refuses outsiders, self trades and anything after cancel", function()
            local session = negotiation.new("s", A, B)
            local ok, why = negotiation.apply(session, 99, { kind = "cancel" }, 0)
            expect(why).to.equal("not_party")
            expect(function()
                negotiation.new("s", A, A)
            end).to.throw()
            negotiation.apply(session, B, { kind = "cancel" }, 0)
            ok, why = negotiation.apply(session, A, { kind = "accept", version = session.version }, 0)
            expect(ok).to.equal(false)
            expect(why).to.equal("closed")
        end)
    end)
end
