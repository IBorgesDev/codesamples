return function()
    local server_script_service = game:GetService("ServerScriptService")
    local archive = require(server_script_service.Server.live_event.archive)

    local function snapshot(totals, at, completed_at, state)
        return {
            state = state or "live",
            version = 1,
            totals = totals,
            completed_at = completed_at,
            ends_at = nil,
            servers = 1,
            replicas = 1,
            at = at,
        }
    end

    describe("live event archive", function()
        it("keeps the highest count per option, so a MemoryStore reset never lowers a counter", function()
            local stored = snapshot({ fish = 900 }, 10)
            local reset = snapshot({ fish = 40 }, 20)
            expect(archive.merge("counter", stored, reset)).to.equal(nil)
            local merged = archive.merge("counter", stored, snapshot({ fish = 950 }, 30)) :: any
            expect(merged.totals.fish).to.equal(950)
        end)

        it("keeps the first completion and never reopens a closed event", function()
            local completed = snapshot({ fish = 1000 }, 10, 8, "completed")
            local merged = archive.merge("counter", completed, snapshot({ fish = 1200 }, 20, 15, "completed")) :: any
            expect(merged.completed_at).to.equal(8)
            local closed = snapshot({ fish = 1200 }, 30, 8, "closed")
            local after = archive.merge("counter", closed, snapshot({ fish = 1300 }, 40, nil, "live")) :: any
            expect(after.state).to.equal("closed")
        end)

        it("keeps the latest vote snapshot, since votes can move between options", function()
            local stored = snapshot({ kraken = 5, megalodon = 3 }, 10)
            local later = snapshot({ kraken = 4, megalodon = 4 }, 20)
            expect((archive.merge("vote", stored, later) :: any).totals.kraken).to.equal(4)
            expect(archive.merge("vote", later, stored)).to.equal(nil)
        end)

        it("seeds the display floor only for counters", function()
            expect(archive.floor("counter", snapshot({ fish = 7 }, 1)).fish).to.equal(7)
            expect(next(archive.floor("vote", snapshot({ kraken = 7 }, 1)))).to.equal(nil)
            expect(next(archive.floor("counter", nil))).to.equal(nil)
        end)
    end)
end
