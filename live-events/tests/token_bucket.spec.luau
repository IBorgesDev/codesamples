return function()
    local replicated_storage = game:GetService("ReplicatedStorage")
    local token_bucket = require(replicated_storage.Shared.net.token_bucket)

    local function fake_clock()
        local now = 0
        return function()
            return now
        end, function(dt: number)
            now += dt
        end
    end

    it("allows a full burst, then refuses", function()
        local clock = fake_clock()
        local limiter = token_bucket.new(2, 3, clock)

        for _ = 1, 3 do
            expect(limiter:take("p")).to.equal(true)
        end

        expect(limiter:take("p")).to.equal(false)
    end)

    it("refills at the rate and never above the burst", function()
        local clock, advance = fake_clock()
        local limiter = token_bucket.new(2, 3, clock)

        for _ = 1, 3 do
            limiter:take("p")
        end

        advance(0.5)
        expect(limiter:take("p")).to.equal(true)
        expect(limiter:take("p")).to.equal(false)
        advance(100)
        for _ = 1, 3 do
            expect(limiter:take("p")).to.equal(true)
        end

        expect(limiter:take("p")).to.equal(false)
    end)

    it("keeps keys apart and honours cost", function()
        local clock = fake_clock()
        local limiter = token_bucket.new(1, 4, clock)
        expect(limiter:take("a", 4)).to.equal(true)
        expect(limiter:take("a", 1)).to.equal(false)
        expect(limiter:take("b", 3)).to.equal(true)
    end)

    it("starts a forgotten key from a full bucket", function()
        local clock = fake_clock()
        local limiter = token_bucket.new(1, 2, clock)
        limiter:take("p", 2)
        limiter:forget("p")
        expect(limiter:take("p", 2)).to.equal(true)
    end)
end
