return function()
    local server_script_service = game:GetService("ServerScriptService")
    local deep = require(script.Parent.support.deep)
    local gift = require(server_script_service.Server.trade.gift)

    const SEED = 7

    local function data(coins, items)
        return { coins = coins, items = items or {}, escrow = {}, gift_seq = 0, gift_seen = {}, outbox = {} }
    end

    local function always()
        return true
    end

    local function totals(...)
        local coins, items = 0, 0
        for _, d in { ... } do
            coins += d.coins
            for _ in d.items do
                items += 1
            end

            for _, outgoing in d.outbox do
                coins += outgoing.coins
                for _ in outgoing.items do
                    items += 1
                end
            end
        end

        return coins, items
    end

    describe("gift", function()
        it("moves the gift into the outbox in the same mutation as the debit", function()
            local sender = data(100, { i1 = { kind = "egg_rare" } })
            local tx_id = gift.send(sender, 1, 2, 30, { i1 = { kind = "egg_rare" } }, 10)
            expect(tx_id).to.equal("1:1")
            expect(sender.coins).to.equal(70)
            expect(sender.items.i1).to.equal(nil)
            expect(sender.outbox[tx_id].items.i1.kind).to.equal("egg_rare")
            expect(sender.outbox[tx_id].seq).to.equal(1)
        end)

        it("refuses what the sender does not have and changes nothing", function()
            local sender = data(10)
            local before = deep.copy(sender)
            local tx_id, why = gift.send(sender, 1, 2, 30, {}, 10)
            expect(tx_id).to.equal(nil)
            expect(why).to.equal("coins")
            expect(deep.equal(sender, before)).to.equal(true)
        end)

        it("credits a gift once, however many times it is delivered", function()
            local sender = data(100, { i1 = { kind = "egg_rare" } })
            local receiver = data(0)
            local tx_id = gift.send(sender, 1, 2, 30, { i1 = { kind = "egg_rare" } }, 10) :: string
            local message = gift.message(tx_id, sender.outbox[tx_id])
            expect(gift.receive(receiver, message)).to.equal(true)
            expect(gift.receive(receiver, message)).to.equal(false)
            expect(receiver.coins).to.equal(30)
            expect(receiver.items.i1.kind).to.equal("egg_rare")
        end)

        it("delivers in order and stops at the first failure for that receiver only", function()
            local sender = data(100)
            gift.send(sender, 1, 2, 1, {}, 10)
            gift.send(sender, 1, 3, 1, {}, 10)
            gift.send(sender, 1, 2, 1, {}, 10)
            local sent = {}
            local delivered = gift.deliver(sender, gift.pending(sender), function(to, message)
                table.insert(sent, message.tx_id)
                return to ~= 2
            end, always)

            expect(delivered).to.equal(1)
            expect(table.concat(sent, ",")).to.equal("1:1,1:2")
            expect(sender.outbox["1:1"]).to.be.ok()
            expect(sender.outbox["1:3"]).to.be.ok()
            expect(sender.outbox["1:2"]).to.equal(nil)
        end)

        it("stops delivering once the sender's session is gone", function()
            local sender = data(100)
            gift.send(sender, 1, 2, 1, {}, 10)
            local delivered = gift.deliver(sender, gift.pending(sender), function()
                return true
            end, function()
                return false
            end)

            expect(delivered).to.equal(0)
            expect(sender.outbox["1:1"]).to.be.ok()
        end)

        it("random crashes and resends never create or lose anything", function()
            local random = Random.new(SEED)
            for _ = 1, 200 do
                local sender = data(1000, { i1 = { kind = "egg_rare" }, i2 = { kind = "pet_cat" } })
                local receivers = { [2] = data(0), [3] = data(0) }
                local coins_before, items_before = totals(sender, receivers[2], receivers[3])
                local saved = deep.copy(sender)

                for step = 1, 6 do
                    local to = random:NextInteger(2, 3)
                    local items = {}
                    for item_id, item in sender.items do
                        if random:NextNumber() < 0.3 then
                            items[item_id] = item
                        end
                    end

                    gift.send(sender, 1, to, random:NextInteger(0, 50), items, step)
                    saved = deep.copy(sender)

                    gift.deliver(sender, gift.pending(sender), function(target, message)
                        if random:NextNumber() < 0.3 then
                            return false
                        end

                        gift.receive(receivers[target], message)

                        return random:NextNumber() < 0.7
                    end, always)

                    if random:NextNumber() < 0.5 then
                        saved = deep.copy(sender)
                    end

                    if random:NextNumber() < 0.3 then
                        sender = deep.copy(saved)
                    end
                end

                gift.deliver(sender, gift.pending(sender), function(target, message)
                    gift.receive(receivers[target], message)
                    return true
                end, always)

                local coins_after, items_after = totals(sender, receivers[2], receivers[3])
                if coins_after ~= coins_before or items_after ~= items_before or next(sender.outbox) ~= nil then
                    error(`seed {SEED}: conservation broken`)
                end
            end
        end)

        it("recognizes only well formed gift messages", function()
            expect(gift.is_gift({ kind = "gift", tx_id = "1:1", from = 1, seq = 1, coins = 1, items = {} })).to.equal(
                true
            )
            expect(gift.is_gift({ kind = "gift", tx_id = "1:1", from = 1, seq = 0, coins = 1, items = {} })).to.equal(
                false
            )
            expect(gift.is_gift({ kind = "gift", tx_id = 5, from = 1, seq = 1, coins = 1, items = {} })).to.equal(false)
            expect(gift.is_gift("gift")).to.equal(false)
        end)
    end)
end
