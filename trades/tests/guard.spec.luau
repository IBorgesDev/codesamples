return function()
    local replicated_storage = game:GetService("ReplicatedStorage")
    local server_script_service = game:GetService("ServerScriptService")
    local guard = require(server_script_service.Server.net.guard)
    local remote = require(replicated_storage.Shared.net.remote)

    local t = guard.t
    const NAN = 0 / 0
    const GUID = "0F8FAD5B-D9CB-469F-A165-70867728950E"

    describe("validators", function()
        it("number: finite and in range only", function()
            local v = t.number(0, 10)
            expect(v(5.5)).to.equal(true)
            expect(v(NAN)).to.equal(false)
            expect(v(math.huge)).to.equal(false)
            expect(v(-1)).to.equal(false)
            expect(v("5")).to.equal(false)
        end)

        it("integer: refuses fractions, NaN and out of range", function()
            local v = t.integer(1, 100)
            expect(v(42)).to.equal(true)
            expect(v(4.2)).to.equal(false)
            expect(v(NAN)).to.equal(false)
            expect(v(101)).to.equal(false)
        end)

        it("string: length in bytes and valid UTF-8", function()
            local v = t.string(5)
            expect(v("hello")).to.equal(true)
            expect(v("hello!")).to.equal(false)
            expect(v("\xff\xfe")).to.equal(false)
            expect(v(5)).to.equal(false)
        end)

        it("id: only GUID-shaped strings", function()
            expect(t.id(GUID)).to.equal(true)
            expect(t.id(string.lower(GUID))).to.equal(true)
            expect(t.id(`\{{GUID}\}`)).to.equal(false)
            expect(t.id("not-a-guid")).to.equal(false)
            expect(t.id(GUID .. "A")).to.equal(false)
        end)

        it("literal, vector3 and optional", function()
            local side = t.literal("a", "b")
            expect(side("a")).to.equal(true)
            expect(side("c")).to.equal(false)
            local v = t.vector3(100)
            expect(v(Vector3.new(1, 2, 3))).to.equal(true)
            expect(v(Vector3.new(NAN, 0, 0))).to.equal(false)
            expect(v(Vector3.new(500, 0, 0))).to.equal(false)
            expect(t.optional(t.boolean)(nil)).to.equal(true)
            expect(t.optional(t.boolean)(1)).to.equal(false)
        end)

        it("array: no holes, no extra keys, bounded, every item checked", function()
            local v = t.array(t.id, 3)
            expect(v({ GUID, GUID })).to.equal(true)
            expect(v({})).to.equal(true)
            expect(v({ GUID, GUID, GUID, GUID })).to.equal(false)
            expect(v({ [1] = GUID, [3] = GUID })).to.equal(false)
            expect(v({ GUID, extra = GUID })).to.equal(false)
            expect(v({ GUID, "nope" })).to.equal(false)
            expect(v(GUID)).to.equal(false)
        end)
    end)

    describe("handler", function()
        local player = {} :: any

        it("passes validated arguments through", function()
            local got
            local handle = guard.handler(
                "spec.pass",
                nil,
                { t.id, t.integer(0, 10) },
                function(_, id: string, n: number)
                    got = { id, n }

                    return "ok"
                end
            )
            expect(handle(player, GUID, 3)).to.equal("ok")
            expect(got[1]).to.equal(GUID)
            expect(got[2]).to.equal(3)
        end)

        it("rejects a wrong argument count, including extra arguments", function()
            local calls = 0
            local handle = guard.handler("spec.arity", nil, { t.boolean }, function()
                calls += 1
            end)

            expect(handle(player)).to.equal(remote.REJECTED)
            expect(handle(player, true, "stuffed")).to.equal(remote.REJECTED)
            expect(calls).to.equal(0)
            expect(guard.rejects()["spec.arity"].arity).to.equal(2)
        end)

        it("rejects a bad argument and names its position", function()
            local handle = guard.handler("spec.arg", nil, { t.boolean, t.integer(0, 1) }, function() end)
            expect(handle(player, true, 0.5)).to.equal(remote.REJECTED)
            expect(guard.rejects()["spec.arg"].arg2).to.equal(1)
        end)

        it("rejects over the rate limit", function()
            local now = 0
            local limiter = guard.limiter(1, 2, function()
                return now
            end)

            local handle = guard.handler("spec.rate", limiter, {}, function()
                return true
            end)

            expect(handle(player)).to.equal(true)
            expect(handle(player)).to.equal(true)
            expect(handle(player)).to.equal(remote.REJECTED)
            now += 1
            expect(handle(player)).to.equal(true)
            expect(guard.rejects()["spec.rate"].rate).to.equal(1)
        end)
    end)
end
