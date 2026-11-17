return function()
    local replicated_storage = game:GetService("ReplicatedStorage")
    local server_script_service = game:GetService("ServerScriptService")
    local aggregator = require(server_script_service.Server.live_event.aggregator)
    local counter = require(server_script_service.Server.live_event.counter)
    local memory_store_fake = require(script.Parent.support.memory_store_fake)
    local planner = require(server_script_service.Server.live_event.planner)
    local tuning = require(replicated_storage.Shared.config.tuning)

    const CONFIG = tuning.live_event
    const SERVERS = 300
    const PLAYERS = 20
    const STEP = 0.5
    const SECONDS = 240
    const CRASH_CHANCE = 0.002
    const FISH_PER_PLAYER_SECOND = 0.05
    const LAYOUT = {
        shards_per_group = 4,
        max_replicas = CONFIG.max_replicas,
        close_grace = CONFIG.close_grace,
        candidates = CONFIG.root_candidates,
    }
    const SPEC = { id = "fishing", kind = "counter", options = { "fish" }, goal = nil, ends_at = nil, shards = 12 }
    const LIMITS = {
        write_per_key = tuning.platform.memory_store.write_per_key,
        read_per_key = tuning.platform.memory_store.read_per_key,
    }

    local function percentile(values, p)
        table.sort(values)
        return values[math.max(1, math.ceil(#values * p))] or 0
    end

    local function run(seed)
        local random = Random.new(seed)
        local clock = 0
        local store = memory_store_fake.new(function()
            return clock
        end, LIMITS)
        local servers = {}
        local next_id = 0
        local published = {}
        local crashes = 0
        local lags = {}
        local truth_history = {}
        local last_root_at = -math.huge

        local function spawn()
            next_id += 1
            table.insert(servers, {
                id = `server-{next_id}`,
                entry = counter.entry(),
                next_flush = clock + random:NextNumber() * CONFIG.flush_interval,
                group = { previous = nil },
                root = { previous = nil, cursor = 0 },
                carry = 0,
            })
        end

        local function flushed_total()
            local total = 0
            for _, value in published do
                total += value
            end

            return total
        end

        local function flush(server)
            local entry = counter.copy(server.entry)
            if aggregator.publish(store.ports, SPEC, LAYOUT, server.id, entry) then
                published[server.id] = entry.plus.fish or 0
            end
        end

        local function lead(server, population)
            local group = aggregator.group_of(aggregator.shard_of(server.id, SPEC.shards), LAYOUT)
            local group_role = aggregator.group_role(group)
            if
                aggregator.candidate(
                    server.id,
                    group_role,
                    population / aggregator.groups(SPEC, LAYOUT),
                    CONFIG.group_candidates
                )
                and store.ports.lease.acquire(SPEC.id, group_role, server.id, CONFIG.lease_seconds)
            then
                aggregator.group_pass(store.ports, SPEC, LAYOUT, group, server.group, clock, CONFIG.group_heartbeat)
            end

            if
                aggregator.candidate(server.id, aggregator.root_role(), population, CONFIG.root_candidates)
                and store.ports.lease.acquire(SPEC.id, aggregator.root_role(), server.id, CONFIG.lease_seconds)
            then
                return aggregator.root_pass(
                    store.ports,
                    SPEC,
                    LAYOUT,
                    server.root,
                    clock,
                    CONFIG.total_heartbeat,
                    CONFIG.orphan_after,
                    CONFIG.max_orphans
                )
            end

            return nil
        end

        for _ = 1, SERVERS do
            spawn()
        end

        local population = SERVERS
        local next_aggregate = 0
        local window_ends = 60
        while clock < SECONDS do
            clock += STEP
            if clock >= window_ends then
                store:reset_window()
                window_ends += 60
            end

            for index = #servers, 1, -1 do
                local server = servers[index]
                if random:NextNumber() < CRASH_CHANCE then
                    table.remove(servers, index)
                    crashes += 1
                    spawn()
                else
                    server.carry += PLAYERS * FISH_PER_PLAYER_SECOND * STEP
                    local whole = math.floor(server.carry)
                    if whole > 0 then
                        server.carry -= whole
                        counter.add(server.entry, "fish", whole)
                    end

                    if clock >= server.next_flush then
                        flush(server)
                        server.next_flush = clock + CONFIG.flush_interval + random:NextNumber() * CONFIG.flush_jitter
                    end
                end
            end

            table.insert(truth_history, { at = clock, total = flushed_total() })

            if clock >= next_aggregate then
                next_aggregate = clock + CONFIG.aggregate_interval
                for _, server in servers do
                    local snapshot = lead(server, population)
                    if snapshot and snapshot.at > last_root_at then
                        last_root_at = snapshot.at
                        population = snapshot.servers
                        local shown = snapshot.totals.fish or 0
                        local reached_at = clock
                        for i = #truth_history, 1, -1 do
                            if truth_history[i].total <= shown then
                                reached_at = truth_history[i].at
                                break
                            end
                        end

                        if clock > 30 then
                            table.insert(lags, clock - reached_at)
                        end
                    end
                end
            end
        end

        for _, server in servers do
            flush(server)
        end

        clock += CONFIG.orphan_after
        local final = nil
        for group = 1, aggregator.groups(SPEC, LAYOUT) do
            aggregator.group_pass(store.ports, SPEC, LAYOUT, group, { previous = nil }, clock, 0)
        end

        final = aggregator.root_pass(
            store.ports,
            SPEC,
            LAYOUT,
            { previous = nil, cursor = 0 },
            clock,
            0,
            CONFIG.orphan_after,
            0
        )

        return {
            final = final.totals.fish or 0,
            truth = flushed_total(),
            crashes = crashes,
            throttled = store.usage.throttled,
            lag_p50 = percentile(table.clone(lags), 0.5),
            lag_p95 = percentile(lags, 0.95),
            ru = store.usage.ru,
            servers = final.servers,
        }
    end

    describe("live event simulation", function()
        for _, seed in { 1, 2, Random.new():NextInteger(3, 2 ^ 31 - 1) } do
            it(`{SERVERS} servers with crashes and leader changes add up exactly (seed {seed})`, function()
                local result = run(seed)
                local bound = planner.plan({
                    name = "sim",
                    ccu = SERVERS * PLAYERS,
                    players_per_server = PLAYERS,
                    churn = 1.2,
                    events = 1,
                    options = 1,
                }).staleness_failover
                print(
                    `[live sim] seed {seed}: {result.truth} fish published, total {result.final}, {result.crashes} crashes, `
                        .. `{result.servers} slots, lag p50 {math.round(result.lag_p50 * 10) / 10} s p95 {math.round(
                            result.lag_p95 * 10
                        ) / 10} s `
                        .. `(bound with a leader failover {math.round(bound * 10) / 10} s), {result.throttled} throttled, {math.round(
                            result.ru / (SECONDS / 60)
                        )} RU/min`
                )

                expect(result.final).to.equal(result.truth)
                expect(result.crashes > 0).to.equal(true)
                expect(result.throttled).to.equal(0)
                expect(result.lag_p95 <= bound).to.equal(true)
            end)
        end
    end)
end
