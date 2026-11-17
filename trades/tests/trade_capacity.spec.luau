return function()
    local server_script_service = game:GetService("ServerScriptService")
    local capacity = require(server_script_service.Server.trade.capacity)

    const LOAD = {
        session_minutes = 20,
        cross_trades_per_player_minute = 0.01,
        trade_minutes = 1.5,
        changes_per_trade = 12,
        hints_per_trade = 16,
    }
    const SCENARIOS = {
        { name = "1.13M CCU, a portfolio's live total at 7 per server", ccu = 1_127_077, players_per_server = 7 },
        { name = "1.27M CCU, 20 per server", ccu = 1_273_618, players_per_server = 20 },
        { name = "7.56M CCU, 8 per server", ccu = 7_564_537, players_per_server = 8 },
        { name = "25.8M CCU, 8 per server", ccu = 25_836_222, players_per_server = 8 },
    }
    const CEILING_FLOOR = 25_836_222
    const CEILING_STEP = 10_000
    const CEILING_MAX = 1_000_000_000
    const SERVER_SIZES = { 4, 8 }

    describe("cross-server trade capacity", function()
        for _, scenario in SCENARIOS do
            it(`{scenario.name}: presence, trade sessions and hints fit with 50% headroom`, function()
                local plan = capacity.plan(scenario, LOAD)
                local problems = capacity.check(plan)
                if #problems > 0 then
                    error(table.concat(problems, "\n"))
                end

                print(
                    `[trade capacity] {scenario.name}: {math.round(plan.trades_per_minute)} cross trades/min, `
                        .. `{math.round(plan.ru_share * 10_000) / 100}% of the RU quota, `
                        .. `busiest coordinator map {math.round(plan.busiest_map_ru)} RU/min`
                )
            end)
        end

        it("finds the largest CCU the design fits for each server size", function()
            for _, size in SERVER_SIZES do
                local function problems_at(ccu)
                    return capacity.check(
                        capacity.plan({ name = "ceiling", ccu = ccu, players_per_server = size }, LOAD)
                    )
                end

                local low, high = CEILING_STEP, CEILING_MAX
                while high - low > CEILING_STEP do
                    local middle = math.floor((low + high) / 2)
                    if #problems_at(middle) == 0 then
                        low = middle
                    else
                        high = middle
                    end
                end

                print(
                    `[trade capacity] ceiling at {size} players per server: {math.round(low / 1e4) / 100}M CCU, `
                        .. `first limit: {table.concat(problems_at(high), "; ")}`
                )
                expect(low >= CEILING_FLOOR).to.equal(true)
            end
        end)
    end)
end
