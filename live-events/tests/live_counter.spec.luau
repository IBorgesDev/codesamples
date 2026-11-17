return function()
    local server_script_service = game:GetService("ServerScriptService")
    local counter = require(server_script_service.Server.live_event.counter)
    local deep = require(script.Parent.support.deep)

    local function entry(plus, minus)
        return { plus = plus or {}, minus = minus or {} }
    end

    describe("live counter", function()
        it("accumulates a server's contributions and retractions", function()
            local mine = counter.entry()
            counter.add(mine, "fish", 3)
            counter.add(mine, "fish", 2)
            counter.retract(mine, "fish", 1)
            expect(counter.value(mine).fish).to.equal(4)
        end)

        it("merging is idempotent, commutative and associative", function()
            local x = entry({ fish = 5 }, { fish = 1 })
            local y = entry({ fish = 7, shark = 2 })
            local z = entry({ shark = 4 }, { fish = 3 })
            local function same(a, b)
                return counter.dominates(a, b) and counter.dominates(b, a)
            end

            expect(same(counter.merge(x, x), x)).to.equal(true)
            expect(same(counter.merge(x, y), counter.merge(y, x))).to.equal(true)
            expect(same(counter.merge(counter.merge(x, y), z), counter.merge(x, counter.merge(y, z)))).to.equal(true)
        end)

        it("publishes a server's cumulative entry into an empty shard", function()
            local shard = counter.publish("s1", entry({ fish = 5 }))(nil)
            expect(shard.s1.plus.fish).to.equal(5)
        end)

        it("a retried publish of the same entry writes nothing", function()
            local shard = deep.freeze(counter.publish("s1", entry({ fish = 5 }))(nil))
            expect(counter.publish("s1", entry({ fish = 5 }))(shard)).to.equal(nil)
        end)

        it("a late, older publish never lowers what is stored", function()
            local shard = deep.freeze(counter.publish("s1", entry({ fish = 9 }))(nil))
            expect(counter.publish("s1", entry({ fish = 4 }))(shard)).to.equal(nil)
        end)

        it("a heartbeat with nothing new still refreshes when the server was last seen", function()
            local stored = { plus = { fish = 5 }, minus = {}, seen = 100 }
            local shard = deep.freeze(counter.publish("s1", stored)(nil))
            local beat = counter.publish("s1", { plus = { fish = 5 }, minus = {}, seen = 130 })(shard)
            expect(beat.s1.seen).to.equal(130)
            expect(beat.s1.plus.fish).to.equal(5)
        end)

        it("an older heartbeat never moves last seen back", function()
            local shard = deep.freeze(counter.publish("s1", { plus = { fish = 5 }, minus = {}, seen = 130 })(nil))
            expect(counter.publish("s1", { plus = { fish = 5 }, minus = {}, seen = 100 })(shard)).to.equal(nil)
        end)

        it("keeps the other servers of the shard and never mutates what it read", function()
            local shard = deep.freeze(counter.publish("s1", entry({ fish = 1 }))(nil))
            local next_shard = counter.publish("s2", entry({ fish = 7 }))(shard)
            expect(next_shard.s1.plus.fish).to.equal(1)
            expect(next_shard.s2.plus.fish).to.equal(7)
        end)

        it("sums every server of every shard, with retractions for changed votes", function()
            local totals, servers = counter.totals({
                [1] = { s1 = entry({ red = 10, blue = 2 }, { red = 3 }) },
                [2] = { s2 = entry({ blue = 5 }, { blue = 1 }), s3 = entry({ red = 1 }) },
            })
            expect(totals.red).to.equal(8)
            expect(totals.blue).to.equal(6)
            expect(servers).to.equal(3)
        end)

        it("any interleaving of publishes ends at the same total", function()
            local updates = {
                { "s1", entry({ fish = 2 }) },
                { "s2", entry({ fish = 5 }) },
                { "s1", entry({ fish = 6 }) },
                { "s2", entry({ fish = 3 }) },
                { "s1", entry({ fish = 4 }) },
            }

            for _, order in { { 1, 2, 3, 4, 5 }, { 5, 4, 3, 2, 1 }, { 3, 1, 5, 2, 4 } } do
                local shard = nil
                for _, index in order do
                    local update = updates[index]
                    shard = counter.publish(update[1], update[2])(shard) or shard
                end

                expect((counter.totals({ shard })).fish).to.equal(11)
            end
        end)
    end)
end
