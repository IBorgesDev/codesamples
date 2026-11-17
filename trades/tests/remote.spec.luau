return function()
    local replicated_storage = game:GetService("ReplicatedStorage")
    local server_storage = game:GetService("ServerStorage")
    local remote = require(replicated_storage.Shared.net.remote)

    local function fresh_folder()
        local folder = Instance.new("Folder")
        folder.Name = "RemoteSpec"
        folder.Parent = server_storage

        return folder
    end

    local function tree()
        return {
            demo = {
                intent = remote.to_server(),
                cast = remote.to_client("unreliable"),
                ask = remote.request(),
                view = remote.state(),
            },
        }
    end

    describe("build", function()
        it("creates one instance per remote, named by path, with the right class", function()
            local folder = fresh_folder()
            remote.build(tree(), folder, true)
            local expected = {
                ["demo.intent"] = "RemoteEvent",
                ["demo.cast"] = "UnreliableRemoteEvent",
                ["demo.ask.req"] = "RemoteEvent",
                ["demo.ask.res"] = "RemoteEvent",
                ["demo.view.push"] = "RemoteEvent",
                ["demo.view.sync"] = "RemoteEvent",
            }

            local count = 0

            for _, child in folder:GetChildren() do
                count += 1
                expect(expected[child.Name]).to.equal(child.ClassName)
            end

            expect(count).to.equal(6)
            folder:Destroy()
        end)

        it("reuses existing instances when built again", function()
            local folder = fresh_folder()
            remote.build(tree(), folder, true)
            local first = folder:FindFirstChild("demo.intent")
            remote.build(tree(), folder, true)
            expect(folder:FindFirstChild("demo.intent")).to.equal(first)
            expect(#folder:GetChildren()).to.equal(6)
            folder:Destroy()
        end)

        it("refuses an instance of the wrong class and a leaf that is not a remote", function()
            local folder = fresh_folder()
            local wrong = Instance.new("RemoteEvent")
            wrong.Name = "demo"
            wrong.Parent = folder
            expect(function()
                remote.build({ demo = remote.to_client("unreliable") }, folder, true)
            end).to.throw()
            expect(function()
                remote.build({ broken = 42 } :: any, folder, true)
            end).to.throw()
            folder:Destroy()
        end)
    end)

    describe("respond", function()
        local player = {} :: any

        it("answers (true, value) for a valid id", function()
            local ok, value = remote.respond(function(_, x)
                return (x :: number) * 2
            end, player, 7, 21)
            expect(ok).to.equal(true)
            expect(value).to.equal(42)
        end)

        it("drops calls with an invalid request id", function()
            local calls = 0
            local function handler()
                calls += 1

                return true
            end

            for _, id in { 0, -1, 1.5, 0 / 0, 2 ^ 31, "1", true } do
                expect(remote.respond(handler, player, id)).to.equal(nil)
            end

            expect(calls).to.equal(0)
        end)

        it("hides handler errors from the client", function()
            local ok, value = remote.respond(function()
                error("secret detail")
            end, player, 1)
            expect(ok).to.equal(false)
            expect(value).to.equal("internal")
        end)

        it("turns a guard rejection into (false, rejected)", function()
            local ok, value = remote.respond(function()
                return remote.REJECTED
            end, player, 1)
            expect(ok).to.equal(false)
            expect(value).to.equal("rejected")
        end)
    end)

    describe("state", function()
        it("keeps the last value per player until cleared", function()
            local folder = fresh_folder()
            local view = remote.state()
            remote.build({ view = view }, folder, true)
            local player = {} :: any
            expect(view:get(player)).to.equal(nil)
            view:clear(player)
            expect(view:get(player)).to.equal(nil)
            folder:Destroy()
        end)
    end)
end
