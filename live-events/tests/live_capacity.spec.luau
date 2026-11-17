return function()
    local server_script_service = game:GetService("ServerScriptService")
    local planner = require(server_script_service.Server.live_event.planner)
    local tuning = require(game:GetService("ReplicatedStorage").Shared.config.tuning)

    const SCENARIOS = {
        { name = "85k CCU, typical day", ccu = 85_184, players_per_server = 20, churn = 1.3, events = 2, options = 1 },
        {
            name = "375k CCU, weekly peak",
            ccu = 374_853,
            players_per_server = 20,
            churn = 1.3,
            events = 2,
            options = 1,
        },
        {
            name = "1.27M CCU, 20 per server",
            ccu = 1_273_618,
            players_per_server = 20,
            churn = 1.3,
            events = 2,
            options = 1,
        },
        {
            name = "1.13M CCU, a portfolio's live total at 7 per server",
            ccu = 1_127_077,
            players_per_server = 7,
            churn = 1.5,
            events = 2,
            options = 3,
        },
        {
            name = "7.56M CCU, Saturday peak of a group of games",
            ccu = 7_564_537,
            players_per_server = 8,
            churn = 1.5,
            events = 2,
            options = 3,
        },
        {
            name = "14.3M CCU, single-game peak",
            ccu = 14_293_524,
            players_per_server = 8,
            churn = 1.5,
            events = 2,
            options = 3,
        },
        {
            name = "25.8M CCU, largest single-game peak",
            ccu = 25_836_222,
            players_per_server = 8,
            churn = 1.5,
            events = 2,
            options = 3,
        },
    }
    const MEGABYTE = 1024 * 1024
    const CEILING_FLOORS = { [4] = 7_564_537, [8] = 25_836_222, [20] = 25_836_222 }
    const CEILING_STEP = 10_000
    const CEILING_MAX = 1_000_000_000

    local function round(value, digits)
        local scale = 10 ^ (digits or 0)
        return math.round(value * scale) / scale
    end

    describe("live event capacity", function()
        for _, scenario in SCENARIOS do
            it(`{scenario.name} fits every Roblox limit with 50% headroom`, function()
                local plan = planner.plan(scenario)
                local problems = planner.check(plan)
                print(
                    `[capacity] {scenario.name}: {plan.servers} servers, {plan.shards} shards in {plan.groups} groups, `
                        .. `{plan.replicas} replicas | RU {round(plan.ru_outage / 1e6, 1)}M/min = {round(
                            plan.ru_share * 100,
                            1
                        )}% of quota | `
                        .. `shard key {round(plan.shard_write_ru)} write / {round(plan.shard_read_ru)} read RU/min, {round(
                            plan.shard_bytes
                        )} bytes | `
                        .. `memory {round(plan.memory_bytes / MEGABYTE)} of {round(plan.memory_quota / MEGABYTE)} MB | `
                        .. `root pass {round(plan.root_pass_seconds, 2)} s | stale {round(plan.staleness_typical, 1)} s typical, `
                        .. `{round(plan.staleness_worst, 1)} s worst, {round(plan.staleness_outage, 1)} s without MessagingService | `
                        .. `HTTP path {round(plan.http_service_rps)} req/s`
                )

                if #problems > 0 then
                    error(`{scenario.name}: {table.concat(problems, "; ")}`, 0)
                end
            end)
        end

        it("finds the largest CCU the design fits for each server size", function()
            for size, floor in CEILING_FLOORS do
                local function plan_at(ccu)
                    return planner.plan({
                        name = "ceiling",
                        ccu = ccu,
                        players_per_server = size,
                        churn = 1.5,
                        events = 2,
                        options = 3,
                    })
                end

                local low, high = CEILING_STEP, CEILING_MAX
                while high - low > CEILING_STEP do
                    local middle = math.floor((low + high) / 2)
                    if #planner.check(plan_at(middle)) == 0 then
                        low = middle
                    else
                        high = middle
                    end
                end

                print(
                    `[capacity] ceiling at {size} players per server: {round(low / 1e6, 2)}M CCU, `
                        .. `{math.ceil(low / size)} servers, first limit: {table.concat(
                            planner.check(plan_at(high)),
                            "; "
                        )}`
                )
                expect(low >= floor).to.equal(true)
            end
        end)

        it("each simpler design breaks below a tenth of a 14.3M CCU peak", function()
            local scenario = SCENARIOS[6]
            for _, point in planner.breakpoints(scenario) do
                print(`[capacity] naive: {point.design} breaks at ~{point.max_servers} servers (~{point.max_ccu} CCU)`)
                expect(point.max_ccu < scenario.ccu / 10).to.equal(true)
            end
        end)

        it("caps lease contenders so even a fully widened pool stays under one key's write limit", function()
            local passes = 60 / tuning.live_event.aggregate_interval
            local per_key = planner.max_contenders() * passes * 2
            expect(per_key <= tuning.platform.memory_store.write_per_key * tuning.platform.safety).to.equal(true)
            expect(planner.max_contenders() >= tuning.live_event.root_candidates).to.equal(true)
        end)

        it("never lists a hash map: one listing would cost more than a whole pass at peak scale", function()
            local listing = planner.listing_ru()
            local pass = planner.pass_cost(tuning.live_event.shards_per_group)
            print(
                `[capacity] a full ListItemsAsync costs ~{listing} RU (measured); a 128-shard group pass by key costs {pass} RU`
            )
            expect(listing > pass).to.equal(true)
        end)

        it("fits a tiny game's quota: passes slow down only when the budget demands it", function()
            local tiny = planner.pass_interval(1, 2, 1)
            local busy = planner.pass_interval(100_000, 2, tuning.live_event.shards_per_group)
            print(`[capacity] pass interval: {round(tiny, 1)} s at 1 CCU, {round(busy, 1)} s at 100k CCU`)
            expect(tiny >= busy).to.equal(true)
            expect(busy).to.equal(tuning.live_event.aggregate_interval)
        end)

        it("replicas and polling grow with the server count and stay inside the read limit", function()
            local small = planner.replicas(10, 1024)
            local large = planner.replicas(3_000_000, 1024)
            expect(small).to.equal(1)
            expect(large).to.equal(1024)
            expect(planner.poll_interval(3_000_000, large) > planner.poll_interval(10, small)).to.equal(true)
        end)
    end)
end
