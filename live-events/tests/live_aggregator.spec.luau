return function()
    local replicated_storage = game:GetService("ReplicatedStorage")
    local server_script_service = game:GetService("ServerScriptService")
    local aggregator = require(server_script_service.Server.live_event.aggregator)
    local hash = require(replicated_storage.Shared.util.hash)
    local memory_store_fake = require(script.Parent.support.memory_store_fake)

    const LAYOUT = { shards_per_group = 2, max_replicas = 3, close_grace = 60, candidates = 8 }
    const SPEC = {
        id = "fishing",
        kind = "counter",
        options = { "fish" },
        goal = { option = "fish", target = 100 },
        ends_at = 5_000,
        shards = 6,
    }
    const HEARTBEAT = 10
    const ORPHAN_AFTER = 30

    local function entry(fish)
        return { plus = { fish = fish }, minus = {} }
    end

    local function world()
        return memory_store_fake.new(function()
            return 1_000
        end)
    end

    local function publish(store, server_id, fish)
        return aggregator.publish(store.ports, SPEC, LAYOUT, server_id, entry(fish))
    end

    local function group_pass(store, group, at)
        return aggregator.group_pass(store.ports, SPEC, LAYOUT, group, { previous = nil }, at, HEARTBEAT)
    end

    local function root_pass(store, root, at, max_orphans)
        return aggregator.root_pass(store.ports, SPEC, LAYOUT, root, at, HEARTBEAT, ORPHAN_AFTER, max_orphans or 3)
    end

    local function snapshot(version, at): any
        return { state = "live", version = version, totals = {}, servers = 0, replicas = 1, at = at }
    end

    describe("hash", function()
        it("matches the FNV-1a 32-bit reference vectors", function()
            expect(hash.fnv1a32("")).to.equal(0x811c9dc5)
            expect(hash.fnv1a32("a")).to.equal(0xe40c292c)
            expect(hash.fnv1a32("foobar")).to.equal(0xbf9cf968)
        end)

        it("spreads servers evenly over the shards", function()
            local counts = {}
            for n = 1, 4_000 do
                local shard = aggregator.shard_of(`server-{n}`, 16)
                counts[shard] = (counts[shard] or 0) + 1
            end

            for shard = 1, 16 do
                expect(counts[shard] > 175 and counts[shard] < 325).to.equal(true)
            end
        end)
    end)

    describe("layout", function()
        it("splits the shards into groups of known keys", function()
            expect(aggregator.groups(SPEC, LAYOUT)).to.equal(3)
            expect(aggregator.group_of(1, LAYOUT)).to.equal(1)
            expect(aggregator.group_of(4, LAYOUT)).to.equal(2)
            expect(table.concat(aggregator.shards_in(3, SPEC, LAYOUT), ",")).to.equal("5,6")
        end)

        it("lets everyone contest while the population is small, and about `wanted` at any scale", function()
            expect(aggregator.candidate("s1", "root", 0, 8)).to.equal(true)
            for _, population in { 1_000, 100_000, 3_000_000 } do
                local hits = 0
                for n = 1, 20_000 do
                    if aggregator.candidate(`server-{n}`, "root", population, 8) then
                        hits += 1
                    end
                end

                local expected = 20_000 * 8 / population
                expect(math.abs(hits - expected) <= math.max(4, expected * 0.5)).to.equal(true)
            end
        end)
    end)

    describe("aggregator", function()
        it("sums every server through the shards and group partials into one total", function()
            local store = world()
            for n = 1, 10 do
                publish(store, `server-{n}`, n)
            end

            for group = 1, 3 do
                group_pass(store, group, 1_000)
            end

            local result = root_pass(store, { previous = nil, cursor = 0 }, 1_000)
            expect(result.totals.fish).to.equal(55)
            expect(result.servers).to.equal(10)
        end)

        it("counts dead servers in the total but only live ones in the population", function()
            local layout =
                { shards_per_group = 2, max_replicas = 3, close_grace = 60, candidates = 8, live_window = 90 }
            local store = world()
            for n = 1, 17 do
                aggregator.publish(
                    store.ports,
                    SPEC,
                    layout,
                    `dead-{n}`,
                    { plus = { fish = 1 }, minus = {}, seen = 100 }
                )
            end

            aggregator.publish(store.ports, SPEC, layout, "alive", { plus = { fish = 5 }, minus = {}, seen = 990 })
            for group = 1, 3 do
                aggregator.group_pass(store.ports, SPEC, layout, group, { previous = nil }, 1_000, HEARTBEAT)
            end

            local result = aggregator.root_pass(
                store.ports,
                SPEC,
                layout,
                { previous = nil, cursor = 0 },
                1_000,
                HEARTBEAT,
                ORPHAN_AFTER,
                3
            ) :: any
            expect(result.totals.fish).to.equal(22)
            expect(result.servers).to.equal(18)
            expect(result.live).to.equal(1)
            expect(aggregator.population(result)).to.equal(1)
        end)

        it("a lone live server among many dead entries is always a candidate", function()
            local stale = { state = "live", version = 70, totals = {}, servers = 18, live = 1, replicas = 1, at = 0 }
            for n = 1, 50 do
                local server_id = `server-{n}`
                expect(aggregator.candidate(server_id, "group:1", aggregator.population(stale :: any), 3)).to.equal(
                    true
                )
                expect(aggregator.candidate(server_id, "root", aggregator.population(stale :: any), 8)).to.equal(true)
            end
        end)

        it("widens the candidate pool while the total stays stale, up to what one lease key can take", function()
            expect(aggregator.widened(8, 0, 30, 41)).to.equal(8)
            expect(aggregator.widened(8, 29, 30, 41)).to.equal(8)
            expect(aggregator.widened(8, 30, 30, 41)).to.equal(16)
            expect(aggregator.widened(8, 65, 30, 41)).to.equal(32)
            expect(aggregator.widened(8, 3_600, 30, 41)).to.equal(41)
        end)

        it(
            "an outdated count cannot stall the total: after a stale minute every server of 18 is a candidate",
            function()
                local old = { state = "live", version = 70, totals = {}, servers = 18, replicas = 1, at = 0 }
                local wanted = aggregator.widened(8, 60, 30, 41)
                for n = 1, 50 do
                    expect(aggregator.candidate(`server-{n}`, "root", aggregator.population(old :: any), wanted)).to.equal(
                        true
                    )
                end
            end
        )

        it("falls back to the server count for snapshots that carry no live count", function()
            expect(aggregator.population({ servers = 12 } :: any)).to.equal(12)
            expect(aggregator.population(nil)).to.equal(0)
        end)

        it("a retried publish changes nothing", function()
            local store = world()
            publish(store, "s1", 7)
            publish(store, "s1", 7)
            expect(root_pass(store, { previous = nil, cursor = 0 }, 1_000).totals.fish).to.equal(7)
        end)

        it("the root adopts groups that have no partial, a few per pass", function()
            local store = world()
            for n = 1, 40 do
                publish(store, `server-{n}`, 1)
            end

            local root = { previous = nil, cursor = 0 }
            local first = root_pass(store, root, 1_000, 2)
            local second = root_pass(store, root, 1_002, 2)
            expect(first.totals.fish < 40).to.equal(true)
            expect(second.totals.fish).to.equal(40)
        end)

        it("completes the goal once and keeps the first completion time", function()
            local first = aggregator.next(SPEC, nil, { fish = 120 }, 3, 1, 1_000, 60)
            local second = aggregator.next(SPEC, first, { fish = 150 }, 3, 1, 1_010, 60)
            expect(first.state).to.equal("completed")
            expect(second.completed_at).to.equal(1_000)
            expect(second.version).to.equal(2)
        end)

        it("closes after the grace period and freezes the totals", function()
            local live = aggregator.next(SPEC, nil, { fish = 10 }, 1, 1, 5_030, 60)
            local closed = aggregator.next(SPEC, live, { fish = 12 }, 1, 1, 5_060, 60)
            local after = aggregator.next(SPEC, closed, { fish = 99 }, 1, 1, 6_000, 60)
            expect(live.state).to.equal("live")
            expect(closed.state).to.equal("closed")
            expect(after.totals.fish).to.equal(12)
        end)

        it("a new root writes nothing until it has read the current total", function()
            local store = world()
            store:fail("totals")
            local result, why = root_pass(store, { previous = nil, cursor = 0 }, 1_000)
            expect(result).to.equal(nil)
            expect(why).to.equal("total_read_failed")
        end)

        it("a root that cannot read the partials publishes nothing rather than a partial total", function()
            local store = world()
            publish(store, "s1", 5)
            store:fail("partials")
            local _, why = root_pass(store, { previous = nil, cursor = 0 }, 1_000)
            expect(why).to.equal("partials_read_failed")
        end)

        it("a stale root cannot overwrite a newer total: replicas are fenced by version", function()
            local store = world()
            publish(store, "s1", 5)
            local fresh = { previous = nil, cursor = 0 }
            root_pass(store, fresh, 1_000)
            publish(store, "s1", 9)
            group_pass(store, aggregator.group_of(aggregator.shard_of("s1", SPEC.shards), LAYOUT), 1_002)
            root_pass(store, fresh, 1_002)
            store.ports.totals.write("fishing", 1, aggregator.next(SPEC, snapshot(0, 0), { fish = 1 }, 1, 1, 1_003, 60))
            local _, current = store.ports.totals.read("fishing", 1)
            expect(current.totals.fish).to.equal(9)
        end)

        it("only rewrites an unchanged total when the heartbeat is due", function()
            local store = world()
            publish(store, "s1", 3)
            local root = { previous = nil, cursor = 0 }
            local a = root_pass(store, root, 1_000)
            local b = root_pass(store, root, 1_005)
            local c = root_pass(store, root, 1_011)
            expect(b).to.equal(a)
            expect(c.version).to.equal(1)
            expect(c.at).to.equal(1_011)
        end)

        it("readers take a snapshot only when it is newer", function()
            local old = snapshot(3, 100)
            expect(aggregator.newer(old, snapshot(4, 90))).to.equal(true)
            expect(aggregator.newer(old, snapshot(3, 110))).to.equal(true)
            expect(aggregator.newer(old, snapshot(2, 200))).to.equal(false)
            expect(aggregator.newer(nil, old)).to.equal(true)
        end)
    end)
end
