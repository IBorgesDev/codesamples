return function()
    local server_script_service = game:GetService("ServerScriptService")
    local inventory = require(server_script_service.Server.trade.inventory)

    local function data(coins, items)
        return {
            coins = coins,
            items = items,
            escrow = {},
            gift_seq = 0,
            gift_seen = {},
            outbox = {},
        }
    end

    describe("inventory snapshot", function()
        it("sends ids and kinds only, never the server's item tables", function()
            local snapshot = inventory.snapshot(data(10, { i1 = { kind = "pet_cat" } }) :: any)
            expect(snapshot.coins).to.equal(10)
            expect(snapshot.items.i1).to.equal("pet_cat")
        end)

        it("changes its fingerprint when coins or items change, whatever the table order", function()
            local _, first =
                inventory.snapshot(data(10, { i1 = { kind = "pet_cat" }, i2 = { kind = "egg_rare" } }) :: any)
            local _, same =
                inventory.snapshot(data(10, { i2 = { kind = "egg_rare" }, i1 = { kind = "pet_cat" } }) :: any)
            local _, fewer = inventory.snapshot(data(10, { i1 = { kind = "pet_cat" } }) :: any)
            local _, richer =
                inventory.snapshot(data(11, { i1 = { kind = "pet_cat" }, i2 = { kind = "egg_rare" } }) :: any)
            expect(same).to.equal(first)
            expect(fewer).never.to.equal(first)
            expect(richer).never.to.equal(first)
        end)
    end)
end
