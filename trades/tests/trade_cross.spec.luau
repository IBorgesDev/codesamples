return function()
    local server_script_service = game:GetService("ServerScriptService")
    local coordinator = require(server_script_service.Server.trade.coordinator)
    local cross = require(server_script_service.Server.trade.cross)
    local deep = require(script.Parent.support.deep)
    local protocol = require(server_script_service.Server.trade.protocol)
    local world = require(script.Parent.support.world)

    const START = 1_000

    local function fake_coordinator()
        local data = {}
        local coord = {
            presence_set = function()
                return true
            end,
            presence_clear = function()
                return true
            end,
            presence_get = function()
                return true, nil
            end,
            create = function(shared)
                data[shared.session.id] = deep.copy(shared)
                return true
            end,
            change = function(session_id, change)
                local result: { why: string? } = { why = nil }
                local stored = coordinator.change_transform(change, result)(deep.copy(data[session_id]))
                if stored == nil then
                    return false, nil, result.why
                end

                data[session_id] = deep.copy(stored)
                return true, deep.copy(stored), nil
            end,
            get = function(session_id)
                return true, deep.copy(data[session_id])
            end,
            send = function()
                return true
            end,
        }

        return coord, data
    end

    local function setup()
        local sim = world.new(11, world.NO_FAULTS, { servers = 2, players = 2, items = 3 })
        table.clear(sim.tasks)
        local coord = fake_coordinator()
        local a, b = sim.online[1], sim.online[2]
        coord.create(cross.new("trade", 1, 2, "server-a", "server-b"))
        local ids = {}
        for item_id in b.data.items do
            table.insert(ids, item_id)
        end

        table.sort(ids)
        local item_id = ids[1]

        return sim, coord, a, b, item_id
    end

    local function agree(coord, b, item_id)
        cross.apply(
            coord,
            "trade",
            2,
            { kind = "add", item_id = item_id, item = table.clone(b.data.items[item_id]) },
            START
        )
        cross.apply(coord, "trade", 1, { kind = "coins", amount = 20 }, START)
        local _, shared = coord.get("trade")
        cross.apply(coord, "trade", 1, { kind = "accept", version = shared.session.version }, START)
        cross.apply(coord, "trade", 2, { kind = "accept", version = shared.session.version }, START)
        local _, locked = coord.get("trade")

        return locked.session.lock_at
    end

    local function expect_clean(sim)
        sim:quiesce()
        local problems = sim:check()
        if #problems > 0 then
            error(table.concat(problems, "\n"))
        end
    end

    local function shared_of(coord)
        local _, shared = coord.get("trade")
        return shared
    end

    describe("cross-server trade", function()
        it("commits through the shared session, driven by polling alone", function()
            local sim, coord, a, b, item_id = setup()
            local lock_at = agree(coord, b, item_id)
            expect((cross.commit(coord, sim.ports, "trade", sim:account(a), "tx", lock_at - 1))).to.equal("waiting")
            expect((cross.commit(coord, sim.ports, "trade", sim:account(a), "tx", lock_at))).to.equal("open")
            expect(shared_of(coord).opened).to.equal(true)
            expect(cross.prepare(coord, sim.ports, shared_of(coord), sim:account(b))).to.equal("committed")
            expect(cross.resume(coord, sim.ports, shared_of(coord), sim:account(a))).to.equal("committed")
            expect(a.data.items[item_id]).to.be.ok()
            expect_clean(sim)
        end)

        it("refuses offer changes once the trade is locked", function()
            local sim, coord, a, b, item_id = setup()
            local lock_at = agree(coord, b, item_id)
            cross.commit(coord, sim.ports, "trade", sim:account(a), "tx", lock_at)
            local ok, _, why = cross.apply(coord, "trade", 1, { kind = "coins", amount = 5 }, lock_at)
            expect(ok).to.equal(false)
            expect(why).to.equal("locked")
        end)

        it("locks once: a second server racing to commit only waits", function()
            local sim, coord, a, b, item_id = setup()
            local lock_at = agree(coord, b, item_id)
            cross.commit(coord, sim.ports, "trade", sim:account(a), "tx", lock_at)
            local again = cross.commit(coord, sim.ports, "trade", sim:account(a), "tx2", lock_at)
            expect(again).to.equal("waiting")
            expect(next(a.data.escrow)).to.equal("tx")
        end)

        it("b never prepares before a's record exists", function()
            local sim, coord, _, b, item_id = setup()
            local lock_at = agree(coord, b, item_id)
            coord.change("trade", function(shared)
                shared.tx_id = "tx"
                shared.locked_at = lock_at
                return true, nil
            end)
            expect(cross.prepare(coord, sim.ports, shared_of(coord), sim:account(b))).to.equal(nil)
            expect(next(b.data.escrow)).to.equal(nil)
        end)

        it("b abandoning a silent a leaves a tombstone that refunds a late opener", function()
            local sim, coord, a, b, item_id = setup()
            local lock_at = agree(coord, b, item_id)
            coord.change("trade", function(shared)
                shared.tx_id = "tx"
                shared.locked_at = lock_at
                return true, nil
            end)
            expect(cross.abandon(coord, sim.ports, shared_of(coord), "a_silent")).to.equal("aborted")
            expect(shared_of(coord).outcome).to.equal("aborted")
            local session = shared_of(coord).session
            local a_side = { user_id = 1, coins = session.a.coins, items = session.a.items, ready = false }
            local b_side = { user_id = 2, coins = session.b.coins, items = session.b.items, ready = false }
            local late = protocol.open(sim.ports, sim:account(a), "tx", a_side, b_side, session.version)
            expect(late).to.equal("aborted")
            expect(next(a.data.escrow)).to.equal(nil)
            expect_clean(sim)
        end)

        it("abandoning after b's vote keeps the commit", function()
            local sim, coord, a, b, item_id = setup()
            local lock_at = agree(coord, b, item_id)
            cross.commit(coord, sim.ports, "trade", sim:account(a), "tx", lock_at)
            local opened = shared_of(coord)
            protocol.prepare(sim.ports, sim:account(b), "tx")
            expect(cross.abandon(coord, sim.ports, opened, "a_silent")).to.equal("committed")
            expect(cross.resume(coord, sim.ports, shared_of(coord), sim:account(a))).to.equal("committed")
            expect(a.data.items[item_id]).to.be.ok()
            expect_clean(sim)
        end)

        it("b spending the item before preparing aborts the trade and refunds a", function()
            local sim, coord, a, b, item_id = setup()
            local lock_at = agree(coord, b, item_id)
            cross.commit(coord, sim.ports, "trade", sim:account(a), "tx", lock_at)
            b.data.items[item_id] = nil
            expect(cross.prepare(coord, sim.ports, shared_of(coord), sim:account(b))).to.equal("aborted")
            expect(cross.resume(coord, sim.ports, shared_of(coord), sim:account(a))).to.equal("aborted")
            expect(next(a.data.escrow)).to.equal(nil)
        end)

        it("records the outcome once", function()
            local _, coord = setup()
            expect(cross.record(coord, "trade", "committed", nil)).to.equal(true)
            expect(cross.record(coord, "trade", "aborted", "late")).to.equal(false)
        end)
    end)
end
