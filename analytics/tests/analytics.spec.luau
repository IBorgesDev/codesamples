return function()
    local server_script_service = game:GetService("ServerScriptService")
    local server_storage = game:GetService("ServerStorage")
    local buffer = require(server_script_service.Server.analytics.buffer)
    local transport = require(server_script_service.Server.analytics.transport)
    local validate = require(server_script_service.Server.analytics.validate)
    local schema = require(server_storage.Schema.events) :: any
    local fixtures = require(server_storage.Schema.fixtures) :: any

    const SEED = 23

    local function event(n)
        return { name = "live_reward", at = n, weight = 1, props = { event_id = `e{n}` } }
    end

    describe("analytics validation", function()
        for _, case in fixtures.events do
            it(`agrees with the shared fixture: {case.why}`, function()
                local ok = validate.event(schema, case.event)
                expect(ok).to.equal(case.valid)
            end)
        end

        it("turns a sample rate into a weight", function()
            expect(validate.weight(schema.events.live_contribution)).to.equal(10)
            expect(validate.weight(schema.events.trade_completed)).to.equal(1)
        end)
    end)

    describe("analytics buffer", function()
        it("batches in order and numbers each batch once", function()
            local queue = buffer.new(10)
            for n = 1, 5 do
                buffer.push(queue, event(n))
            end

            local first = buffer.take(queue, 3, 0) :: any
            expect(first.seq).to.equal(1)
            expect(first.events[1].at).to.equal(1)
            expect(#first.events).to.equal(3)
            buffer.acked(queue)
            local second = buffer.take(queue, 3, 0) :: any
            expect(second.seq).to.equal(2)
            expect(second.events[1].at).to.equal(4)
        end)

        it("retries the same batch with the same number, so the service can drop the duplicate", function()
            local queue = buffer.new(10)
            buffer.push(queue, event(1))
            local batch = buffer.take(queue, 10, 0) :: any
            buffer.failed(queue, 100, 5)
            expect(buffer.ready(queue, 104)).to.equal(false)
            expect(buffer.ready(queue, 105)).to.equal(true)
            buffer.push(queue, event(2))
            local again = buffer.take(queue, 10, 0) :: any
            expect(again).to.equal(batch)
            expect(again.seq).to.equal(1)
            expect(again.attempts).to.equal(1)
        end)

        it("drops the oldest events when full and reports how many in the next batch", function()
            local queue = buffer.new(3)
            for n = 1, 5 do
                buffer.push(queue, event(n))
            end

            local batch = buffer.take(queue, 10, 0) :: any
            expect(batch.dropped).to.equal(2)
            expect(batch.events[1].at).to.equal(3)
            expect(#batch.events).to.equal(3)
        end)

        it("never loses or repeats an event under random outages", function()
            local random = Random.new(SEED)
            local queue = buffer.new(1_000)
            local delivered: { [number]: boolean } = {}
            local seen_seqs: { [number]: boolean } = {}
            local pushed = 0
            for step = 1, 2_000 do
                if random:NextNumber() < 0.6 then
                    pushed += 1
                    buffer.push(queue, event(pushed))
                end

                if buffer.ready(queue, step) then
                    local batch = buffer.take(queue, 50, 0)
                    if batch then
                        local lands = random:NextNumber() < 0.7
                        local acked = lands and random:NextNumber() < 0.8
                        if lands and not seen_seqs[batch.seq] then
                            seen_seqs[batch.seq] = true
                            for _, item in batch.events do
                                if delivered[item.at] then
                                    error(`seed {SEED}: event {item.at} delivered twice`)
                                end

                                delivered[item.at] = true
                            end
                        end

                        if acked then
                            buffer.acked(queue)
                        else
                            buffer.failed(queue, step, random:NextInteger(0, 3))
                        end
                    end
                end
            end

            while buffer.take(queue, 50, 0) do
                local batch = buffer.take(queue, 50, 0) :: any
                if not seen_seqs[batch.seq] then
                    seen_seqs[batch.seq] = true
                    for _, item in batch.events do
                        delivered[item.at] = true
                    end
                end

                buffer.acked(queue)
            end

            for n = 1, pushed do
                if not delivered[n] then
                    error(`seed {SEED}: event {n} lost`)
                end
            end
        end)
    end)

    describe("analytics retries", function()
        it("gives a batch up only once its dedupe key may have expired on the service", function()
            local queue = buffer.new(10)
            buffer.push(queue, event(1))
            buffer.take(queue, 10, 100)
            expect(buffer.expired(queue, 100 + 3_000, 3_000)).to.equal(false)
            expect(buffer.expired(queue, 100 + 3_001, 3_000)).to.equal(true)
        end)
    end)

    describe("analytics transport", function()
        it("drops only what the service will never accept", function()
            expect(transport.classify(200)).to.equal("ok")
            expect(transport.classify(400)).to.equal("drop")
            expect(transport.classify(413)).to.equal("drop")
            expect(transport.classify(401)).to.equal("retry")
            expect(transport.classify(429)).to.equal("retry")
            expect(transport.classify(503)).to.equal("retry")
        end)
    end)
end
