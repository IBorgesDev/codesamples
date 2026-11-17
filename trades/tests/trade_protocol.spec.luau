return function()
    local replicated_storage = game:GetService("ReplicatedStorage")
    local server_script_service = game:GetService("ServerScriptService")
    local ledger = require(server_script_service.Server.trade.ledger)
    local protocol = require(server_script_service.Server.trade.protocol)
    local trade_record = require(server_script_service.Server.trade.record)
    local tuning = require(replicated_storage.Shared.config.tuning)
    local world = require(script.Parent.support.world)

    local function first_item(session)
        local ids = {}

        for item_id in session.data.items do
            table.insert(ids, item_id)
        end

        table.sort(ids)

        return ids[1]
    end

    local function setup(servers)
        local sim = world.new(7, world.NO_FAULTS, { servers = servers, players = 2, items = 3 })
        table.clear(sim.tasks)
        local sa, sb = sim.online[1], sim.online[2]
        local ia, ib = first_item(sa), first_item(sb)
        local a = { user_id = 1, coins = 20, items = { [ia] = table.clone(sa.data.items[ia]) }, ready = false }
        local b = { user_id = 2, coins = 5, items = { [ib] = table.clone(sb.data.items[ib]) }, ready = false }

        return sim, sa, sb, a, b, ia, ib
    end

    local function expect_clean(sim)
        sim:quiesce()
        local problems = sim:check()

        if #problems > 0 then
            error(table.concat(problems, "\n"))
        end
    end

    describe("Protocol", function()
        it("a same-server trade commits and moves both offers", function()
            local sim, sa, sb, a, b, ia, ib = setup(1)
            expect(protocol.open(sim.ports, sim:account(sa), "tx", a, b, 1)).to.equal("open")
            expect(protocol.prepare(sim.ports, sim:account(sb), "tx")).to.equal("committed")
            expect(protocol.finalize(sim.ports, sim:account(sa), "tx")).to.equal("committed")
            expect(sa.data.items[ib]).to.be.ok()
            expect(sb.data.items[ia]).to.be.ok()
            expect(sa.data.items[ia]).to.equal(nil)
            expect_clean(sim)
        end)

        it("b no longer has its item: the record aborts and a gets everything back", function()
            local sim, sa, sb, a, b, ia, ib = setup(2)
            protocol.open(sim.ports, sim:account(sa), "tx", a, b, 1)
            sb.data.items[ib] = nil
            local outcome, reason = protocol.prepare(sim.ports, sim:account(sb), "tx")
            expect(outcome).to.equal("aborted")
            expect(reason).to.equal("b_items")
            expect(protocol.finalize(sim.ports, sim:account(sa), "tx")).to.equal("aborted")
            expect(sa.data.items[ia]).to.be.ok()
            expect_clean(sim)
        end)

        it("race: an abort that lands before b votes wins, and b refunds", function()
            local sim, sa, sb, a, b, ia, ib = setup(2)
            protocol.open(sim.ports, sim:account(sa), "tx", a, b, 1)
            local account_b = sim:account(sb)
            local persist = account_b.persist
            account_b.persist = function(durable)
                local saved = persist(durable)
                sim.clock += tuning.trade.record_timeout
                protocol.finalize(sim.ports, sim:account(sa), "tx")

                return saved
            end

            expect(protocol.prepare(sim.ports, account_b, "tx")).to.equal("aborted")
            expect(sim.records.tx.state).to.equal("aborted")
            expect(sa.data.items[ia]).to.be.ok()
            expect(sb.data.items[ib]).to.be.ok()
            expect_clean(sim)
        end)

        it("race: a vote that lands before the abort wins, and the abort settles as committed", function()
            local sim, sa, sb, a, b, ia, ib = setup(2)
            protocol.open(sim.ports, sim:account(sa), "tx", a, b, 1)
            sim.clock += tuning.trade.record_timeout
            local racing = {
                now = sim.ports.now,
                later = sim.ports.later,
                records = {
                    read = sim.ports.records.read,
                    update = function(tx_id, transform)
                        protocol.prepare(sim.ports, sim:account(sb), tx_id)
                        return sim.ports.records.update(tx_id, transform)
                    end,
                },
            }

            expect(protocol.finalize(racing, sim:account(sa), "tx")).to.equal("committed")
            expect(sa.data.items[ib]).to.be.ok()
            expect(sb.data.items[ia]).to.be.ok()
            expect_clean(sim)
        end)

        it("a record write that landed but reported an error is finished by the other side", function()
            local sim, sa, sb, a, b = setup(2)
            local lossy = {
                now = sim.ports.now,
                later = sim.ports.later,
                records = {
                    read = sim.ports.records.read,
                    update = function(tx_id, transform)
                        sim.ports.records.update(tx_id, transform)
                        return false, "timeout"
                    end,
                },
            }

            expect(protocol.open(lossy, sim:account(sa), "tx", a, b, 1)).to.equal("pending")
            expect(protocol.prepare(sim.ports, sim:account(sb), "tx")).to.equal("committed")
            expect(protocol.finalize(sim.ports, sim:account(sa), "tx")).to.equal("committed")
            expect_clean(sim)
        end)

        it("an escrow left without a record becomes a tombstone, and a late create fails", function()
            local sim, sa, _, a, b, ia = setup(1)
            ledger.hold(sa.data, "tx", "a", a.coins, a.items, sim:now())
            sim:account(sa).persist(function()
                return true
            end)

            expect(protocol.finalize(sim.ports, sim:account(sa), "tx")).to.equal("open")
            sim.clock += tuning.trade.missing_record_grace
            expect(protocol.finalize(sim.ports, sim:account(sa), "tx")).to.equal("aborted")
            expect(sa.data.items[ia]).to.be.ok()
            local _, stored =
                sim.ports.records.update("tx", trade_record.create(trade_record.new("tx", a, b, 1, sim:now())))
            expect(stored.tombstone).to.equal(true)
            expect_clean(sim)
        end)

        it("a session that lost its lock never reaches the store", function()
            local sim, sa, sb, a, b, _, ib = setup(2)
            protocol.open(sim.ports, sim:account(sa), "tx", a, b, 1)
            sim:load(2, sa.server)
            local outcome = protocol.prepare(sim.ports, sim:account(sb), "tx")
            expect(outcome).to.equal("aborted")
            expect(sb.active).to.equal(false)
            expect(sim.profiles[2].saved.items[ib]).to.be.ok()
            expect(next(sim.profiles[2].saved.escrow)).to.equal(nil)
            expect_clean(sim)
        end)
    end)
end
