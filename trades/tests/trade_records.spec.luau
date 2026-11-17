return function()
    local server_script_service = game:GetService("ServerScriptService")
    local records = require(server_script_service.Server.trade.records)
    local trade_record = require(server_script_service.Server.trade.record)

    local function fake()
        local data = {}
        return {
            UpdateAsync = function(_, key, transform)
                local new = transform(data[key])
                if new == nil then
                    return nil
                end

                data[key] = new
                return new
            end,
            GetAsync = function(_, key)
                return data[key], nil
            end,
        }
    end

    local function side(user_id)
        return { user_id = user_id, coins = 0, items = {}, ready = false }
    end

    describe("trade records on a DataStore", function()
        it("returns the stored record when a transform cancels, as UpdateAsync returns nil then", function()
            local store = records.adapter(fake())
            local created = trade_record.new("tx", side(1), side(2), 1, 100)
            store.update("tx", trade_record.create(created))
            local ok, current = store.update("tx", trade_record.create(created))
            expect(ok).to.equal(true)
            expect(current.state).to.equal("open")
        end)

        it("reports a failed call instead of raising, and counts every call", function()
            local broken = {
                UpdateAsync = function()
                    error("DataStore request was throttled")
                end,
                GetAsync = function()
                    error("DataStore request was throttled")
                end,
            }
            local store = records.adapter(broken)
            local ok = store.update("tx", function(current)
                return current
            end)
            local read_ok = store.read("tx")
            expect(ok).to.equal(false)
            expect(read_ok).to.equal(false)
            expect(store.calls()).to.equal(2)
        end)

        it("reads only the value, not the key info", function()
            local store = records.adapter(fake())
            local ok, value = store.read("missing")
            expect(ok).to.equal(true)
            expect(value).to.equal(nil)
        end)
    end)
end
