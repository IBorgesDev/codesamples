return function()
    local server_script_service = game:GetService("ServerScriptService")
    local ledger = require(server_script_service.Server.trade.ledger)
    local trade_record = require(server_script_service.Server.trade.record)
    local world = require(script.Parent.support.world)

    const TRADES = 200

    local function violations_with(target, key, broken)
        local original = target[key]
        target[key] = broken(original)
        local ok, result = pcall(function()
            local sim = world.new(1, world.CHAOS, { servers = 4, players = 10 })
            sim:simulate(TRADES)
            sim:quiesce()

            return sim:check()
        end)

        target[key] = original
        if not ok then
            error(result, 0)
        end

        return result
    end

    describe("the invariant checker catches a broken protocol", function()
        it("settle credits a commit but keeps the escrow (dupe)", function()
            local problems = violations_with(ledger, "settle", function(settle)
                return function(data, record)
                    local entry = data.escrow[record.tx_id]
                    local changed = settle(data, record)

                    if changed and record.state == "committed" then
                        data.escrow[record.tx_id] = entry
                    end

                    return changed
                end
            end)

            expect(#problems > 0).to.equal(true)
        end)

        it("abort overrides a committed record (no commit point)", function()
            local problems = violations_with(trade_record, "abort", function(abort)
                return function(tx_id, reason, now)
                    return function(current)
                        if current and current.state == "committed" then
                            local new = table.clone(current)
                            new.state = "aborted"
                            return new
                        end

                        return abort(tx_id, reason, now)(current)
                    end
                end
            end)

            expect(#problems > 0).to.equal(true)
        end)

        it("a save reports success without landing (vote on an escrow that is not durable)", function()
            local problems = violations_with(world, "account", function(account)
                return function(self, session)
                    local real = account(self, session)
                    local persist = real.persist
                    real.persist = function(durable)
                        if self.random:NextNumber() < 0.3 then
                            return true
                        end

                        return persist(durable)
                    end

                    return real
                end
            end)

            expect(#problems > 0).to.equal(true)
        end)
    end)
end
