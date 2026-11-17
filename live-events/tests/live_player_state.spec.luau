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
        it("decides cast, change, same and foreign", function()
            expect(ballot.decide(nil, "kraken", "s1")).to.equal("cast")
            expect(ballot.decide({ option = "kraken", server = "s1" }, "kraken", "s1")).to.equal("same")
            expect(ballot.decide({ option = "kraken", server = "s1" }, "megalodon", "s1")).to.equal("change")
            expect(ballot.decide({ option = "kraken", server = "s1" }, "megalodon", "s2")).to.equal("foreign")
        end)

        it("a change on the same server moves the vote inside one entry", function()
            local entry = counter.entry()
            ballot.count(entry, nil, "kraken")
            ballot.count(entry, { option = "kraken", server = "s1" }, "megalodon")
            local value = counter.value(entry)
            expect(value.kraken).to.equal(0)
            expect(value.megalodon).to.equal(1)
        end)

        it("never counts a player twice across saves that fail, flushes that never land and crashes", function()
            local random = Random.new(SEED)
            local saved = {}
            local memory = {}
            for player = 1, PLAYERS do
                saved[player] = profile()
            end

            local published: { [string]: { entry: any, by: { [number]: number } } } = {}
            local servers = {}
            local next_server = 0

            local function new_server()
                next_server += 1
                local server = { id = `s{next_server}`, entry = counter.entry(), by = {}, players = {} }
                table.insert(servers, server)
                return server
            end

            local function join(player, server)
                memory[player] = deep.copy(saved[player])
                server.players[player] = true
            end

            for player = 1, PLAYERS do
                join(player, new_server())
            end

            local function home(player)
                for _, server in servers do
                    if server.players[player] then
                        return server
                    end
                end

                return nil
            end

            for _ = 1, ROUNDS do
                local roll = random:NextNumber()
                local player = random:NextInteger(1, PLAYERS)
                local server = home(player)
                if roll < 0.55 and server then
                    local option = OPTIONS[random:NextInteger(1, #OPTIONS)]
                    local data = memory[player]
                    local previous = data.live_votes.boss
                    local decision = ballot.decide(previous, option, server.id)
                    if decision == "cast" or decision == "change" then
                        data.live_votes.boss = { option = option, server = server.id }
                        if random:NextNumber() < 0.8 then
                            saved[player] = deep.copy(data)
                            ballot.count(server.entry, previous, option)
                            server.by[player] = (server.by[player] or 0) + (if previous then 0 else 1)
                        else
                            data.live_votes.boss = previous
                        end
                    end
                elseif roll < 0.8 and server then
                    published[server.id] = { entry = counter.copy(server.entry), by = table.clone(server.by) }
                elseif roll < 0.9 and server then
                    for moved in server.players do
                        server.players[moved] = nil
                        join(moved, new_server())
                    end

                    table.remove(servers, table.find(servers, server))
                elseif server then
                    server.players[player] = nil
                    join(player, servers[random:NextInteger(1, #servers)] or new_server())
                end
            end

            local totals = {}
            local per_player: { [number]: number } = {}
            for _, snapshot in published do
                counter.sum(totals, counter.value(snapshot.entry))
                for player, count in snapshot.by do
                    per_player[player] = (per_player[player] or 0) + count
                end
            end

            local votes = 0
            for _, option in OPTIONS do
                local value = totals[option] or 0
                if value < 0 then
                    error(`seed {SEED}: {option} went negative`)
                end

                votes += value
            end

            local voters = 0
            for player = 1, PLAYERS do
                if saved[player].live_votes.boss then
                    voters += 1
                end

                if (per_player[player] or 0) > 1 then
                    error(`seed {SEED}: player {player} counted {per_player[player]} times`)
                end
            end

            if votes > voters then
                error(`seed {SEED}: {votes} votes for {voters} voters`)
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
