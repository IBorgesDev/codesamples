return function()
    local world = require(script.Parent.support.world)

    const TRADES = 1000

    local function fail_with(label, problems)
        local shown = table.move(problems, 1, math.min(#problems, 10), 1, {})
        error(`{label}: {#problems} violation(s)\n  {table.concat(shown, "\n  ")}`, 0)
    end

    describe("trade chaos", function()
        for _, servers in { 1, 2 } do
            local where = if servers == 1 then "same server" else "cross server"
            it(`one trade survives a crash at every port boundary ({where})`, function()
                local clean = world.new(1, world.NO_FAULTS, { servers = servers, players = 2 })
                clean:one_trade(nil)
                expect(clean.records.tx1.state).to.equal("committed")
                local outcomes = {}

                for boundary = 1, clean.boundaries do
                    local sim = world.new(1, world.NO_FAULTS, { servers = servers, players = 2 })
                    sim:one_trade(boundary)
                    sim:quiesce()
                    local problems = sim:check()

                    if #problems > 0 then
                        fail_with(`{where}, crash at boundary {boundary}`, problems)
                    end

                    local record = sim.records.tx1
                    local state = if record then record.state else "none"
                    outcomes[state] = (outcomes[state] or 0) + 1
                end

                expect(outcomes.committed).to.be.ok()
                expect(outcomes.aborted).to.be.ok()
            end)
        end

        local seeds = { 1, 2, 3, Random.new():NextInteger(4, 2 ^ 31 - 1) }

        for _, seed in seeds do
            it(`{TRADES} trades under chaos keep I1-I5 (seed {seed})`, function()
                local started = os.clock()
                local sim = world.new(seed, world.CHAOS, { servers = 4, players = 10 })
                sim:simulate(TRADES)
                local passes = sim:quiesce()
                local problems = sim:check()

                if passes == math.huge then
                    table.insert(problems, 1, "recovery did not quiesce")
                end

                if #problems > 0 then
                    fail_with(`seed {seed}`, problems)
                end

                print(`[chaos] seed {seed}: {sim:summary()}, {math.round((os.clock() - started) * 1000)} ms`)
                local committed = 0

                for _, record in sim.records do
                    if record.state == "committed" then
                        committed += 1
                    end
                end

                expect(committed > TRADES / 4).to.equal(true)
                expect(sim.stats.crashes > 0).to.equal(true)
                expect(sim.stats.steals > 0).to.equal(true)
            end)
        end
    end)
end
