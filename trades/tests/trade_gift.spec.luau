return function()
    local server_script_service = game:GetService("ServerScriptService")
    local deep = require(script.Parent.support.deep)
    local gift = require(server_script_service.Server.trade.gift)
    local inbox = require(server_script_service.Server.trade.inbox)

    const SEED = 7
    const INBOX_SENDERS = 30
    const INBOX_CAP = 20
    const QUEUE_LIMIT = 40
    const INBOX_ROUNDS = 40
    const INBOX_DRAIN_ROUNDS = 1000

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

        it("reserves a slot in the receiver's inbox once per gift and refuses past the cap", function()
            local ledger, fits = inbox.reserved({}, "1:1", 2)
            expect(fits).to.equal(true)
            local again, still = inbox.reserved(ledger :: any, "1:1", 2)
            expect(again).to.equal(nil)
            expect(still).to.equal(true)
            local two = inbox.reserved(ledger :: any, "3:1", 2)
            local full, refused = inbox.reserved(two :: any, "4:1", 2)
            expect(full).to.equal(nil)
            expect(refused).to.equal(false)
        end)

        it("settles only the reservations the receiver's saved data has credited", function()
            local settled = inbox.settled({ ["1:1"] = true, ["1:2"] = true, ["3:1"] = true }, { ["1"] = 1 })
            expect(settled and settled["1:1"]).to.equal(nil)
            expect(settled and settled["1:2"]).to.equal(true)
            expect(settled and settled["3:1"]).to.equal(true)
            expect(inbox.settled({ ["1:2"] = true }, { ["1"] = 1 })).to.equal(nil)
        end)

        it("never loses a gift to an offline player whose message queue drops the oldest", function()
            local random = Random.new(SEED)
            for _ = 1, 40 do
                local senders, saved_senders = {}, {}
                for s = 1, INBOX_SENDERS do
                    senders[s] = data(1000)
                    saved_senders[s] = deep.copy(senders[s])
                end

                local receiver = data(0)
                local saved_receiver = deep.copy(receiver)
                local queue, ledger, dropped = {}, {}, 0
                local coins_before = totals(receiver, table.unpack(senders))

                local function send(_, message)
                    local after, fits = inbox.reserved(ledger, message.tx_id, INBOX_CAP)
                    if not fits then
                        return false
                    end

                    ledger = after or ledger
                    if random:NextNumber() < 0.1 then
                        return false
                    end

                    table.insert(queue, message)
                    while #queue > QUEUE_LIMIT do
                        table.remove(queue, 1)
                        dropped += 1
                    end

                    return true
                end

                local function come_online(crash)
                    for _, message in queue do
                        gift.receive(receiver, message)
                    end

                    if crash then
                        receiver = deep.copy(saved_receiver)
                        return
                    end

                    queue = {}
                    saved_receiver = deep.copy(receiver)
                    ledger = inbox.settled(ledger, saved_receiver.gift_seen) or ledger
                end

                for round = 1, INBOX_ROUNDS do
                    for s, sender in senders do
                        if random:NextNumber() < 0.5 then
                            gift.send(sender, s, 99, random:NextInteger(1, 5), {}, round)
                        end

                        saved_senders[s] = deep.copy(sender)
                        gift.deliver(sender, gift.pending(sender), send, always)
                        if random:NextNumber() < 0.1 then
                            senders[s] = deep.copy(saved_senders[s])
                        else
                            saved_senders[s] = deep.copy(sender)
                        end
                    end

                    if random:NextNumber() < 0.15 then
                        come_online(random:NextNumber() < 0.3)
                    end
                end

                local function pending_count()
                    local pending = 0
                    for _, sender in senders do
                        pending += #gift.pending(sender)
                    end

                    return pending
                end

                for _ = 1, INBOX_DRAIN_ROUNDS do
                    for _, sender in senders do
                        gift.deliver(sender, gift.pending(sender), send, always)
                    end

                    come_online(false)
                    if pending_count() == 0 then
                        break
                    end
                end

                local pending = pending_count()

                local coins_after = totals(receiver, table.unpack(senders))
                if dropped > 0 or pending > 0 or coins_after ~= coins_before or inbox.count(ledger) > 0 then
                    error(
                        `seed {SEED}: {dropped} dropped, {pending} pending, coins {coins_before} -> {coins_after}, `
                            .. `{inbox.count(ledger)} reserved`
                    )
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
