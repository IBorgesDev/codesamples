return function()
    local server_script_service = game:GetService("ServerScriptService")
    local ballot = require(server_script_service.Server.live_event.ballot)
    local counter = require(server_script_service.Server.live_event.counter)
    local deep = require(script.Parent.support.deep)
    local reward = require(server_script_service.Server.live_event.reward)

    const SEED = 41
    const ROUNDS = 400
    const PLAYERS = 6
    const OPTIONS = { "kraken", "megalodon", "leviathan" }

    local function profile()
        return { coins = 0, live_votes = {}, live_rewards = {} }
    end

    describe("live event ballots", function()
        it("decides cast, change and same, and locks a ballot counted the old way", function()
            local cast = ballot.next(nil, "kraken")
            expect(ballot.decide(nil, "kraken")).to.equal("cast")
            expect(ballot.decide(cast, "kraken")).to.equal("same")
            expect(ballot.decide(cast, "megalodon")).to.equal("change")
            expect(ballot.decide({ option = "kraken", server = "s1" }, "megalodon")).to.equal("locked")
        end)

        it("a change moves the vote inside the player's own entry", function()
            local changed = ballot.next(ballot.next(nil, "kraken"), "megalodon")
            local value = counter.value(ballot.entry(changed))
            expect(value.kraken).to.equal(0)
            expect(value.megalodon).to.equal(1)
            expect(ballot.same(changed, ballot.next(ballot.next(nil, "kraken"), "megalodon"))).to.equal(true)
        end)

        it("counts every saved ballot exactly once across failed saves, lost publishes, crashes and moves", function()
            local random = Random.new(SEED)
            local saved, memory, home = {}, {}, {}
            local stored: { [string]: any } = {}
            local servers = {}
            local next_server = 0

            local function new_server()
                next_server += 1
                local server = { id = next_server, pending = {} }
                table.insert(servers, server)
                return server
            end

            local function join(player, server)
                memory[player] = deep.copy(saved[player])
                home[player] = server
                local cast = memory[player].live_votes.boss
                if cast and cast.plus ~= nil and cast.published ~= true then
                    server.pending[player] = cast
                end
            end

            local function flush(server, success)
                for player, cast in server.pending do
                    if random:NextNumber() < success then
                        local key = counter.voter_key(player)
                        local entry = ballot.entry(cast)
                        stored[key] = if stored[key] then counter.merge(stored[key], entry) else entry
                        server.pending[player] = nil
                        local current = memory[player].live_votes.boss
                        if home[player] == server and ballot.same(current, cast) then
                            current.published = true
                        end
                    end
                end
            end

            local function crash(server)
                table.remove(servers, table.find(servers, server))
                local replacement = new_server()
                for player = 1, PLAYERS do
                    if home[player] == server then
                        join(player, replacement)
                    end
                end
            end

            for player = 1, PLAYERS do
                saved[player] = profile()
                join(player, new_server())
            end

            for _ = 1, ROUNDS do
                local roll = random:NextNumber()
                local player = random:NextInteger(1, PLAYERS)
                local server = home[player]
                if roll < 0.45 then
                    local option = OPTIONS[random:NextInteger(1, #OPTIONS)]
                    local data = memory[player]
                    local previous = data.live_votes.boss
                    local decision = ballot.decide(previous, option)
                    if decision == "cast" or decision == "change" then
                        local cast = ballot.next(previous, option)
                        data.live_votes.boss = cast
                        local outcome = random:NextNumber()
                        if outcome < 0.7 then
                            saved[player] = deep.copy(data)
                            server.pending[player] = cast
                        else
                            if outcome < 0.85 then
                                saved[player] = deep.copy(data)
                            end

                            data.live_votes.boss = previous
                        end
                    end
                elseif roll < 0.65 then
                    flush(server, 0.7)
                elseif roll < 0.75 then
                    saved[player] = deep.copy(memory[player])
                elseif roll < 0.85 then
                    crash(server)
                else
                    saved[player] = deep.copy(memory[player])
                    server.pending[player] = nil
                    join(player, servers[random:NextInteger(1, #servers)])
                end
            end

            for player = 1, PLAYERS do
                join(player, home[player])
            end

            for _, server in servers do
                flush(server, 1)
            end

            local expected: { [string]: number } = {}
            for player = 1, PLAYERS do
                local cast = saved[player].live_votes.boss
                if cast then
                    expected[cast.option] = (expected[cast.option] or 0) + 1
                end
            end

            local totals = counter.totals({ stored }, nil)
            for _, option in OPTIONS do
                if (totals[option] or 0) ~= (expected[option] or 0) then
                    error(
                        `seed {SEED}: {option} counted {totals[option] or 0}, saved ballots say {expected[option] or 0}`
                    )
                end
            end
        end)
    end)

    describe("live event rewards", function()
        it("waits for the goal", function()
            expect(reward.reached(nil)).to.equal(false)
            expect(reward.reached({ completed_at = nil } :: any)).to.equal(false)
            expect(reward.reached({ completed_at = 10 } :: any)).to.equal(true)
        end)

        it("grants once per player, in the same mutation as the mark", function()
            local data = profile()
            expect(reward.grant(data :: any, "world_fishing", 100, 5)).to.equal(true)
            expect(reward.grant(data :: any, "world_fishing", 100, 6)).to.equal(false)
            expect(data.coins).to.equal(100)
            expect(data.live_rewards.world_fishing).to.equal(5)
        end)
    end)
end
