--!strict

local server_script_service = game:GetService("ServerScriptService")

local deep = require(script.Parent.deep)
local types = require(server_script_service.Server.live_event.types)

export type Limits = {
    write_per_key: number,
    read_per_key: number,
}

export type Usage = {
    ru: number,
    throttled: number,
    per_key: { [string]: { read: number, write: number } },
}

export type Fake = {
    ports: types.Ports,
    usage: Usage,
    data: { [string]: any },
    leases: { [string]: { holder: string, until_at: number } },
    clear: (self: Fake) -> (),
    reset_window: (self: Fake) -> (),
    fail: (self: Fake, kind: string?) -> (),
}

local fake = {}

function fake.new(clock: () -> number, limits: Limits?): Fake
    local data: { [string]: any } = {}
    local usage: Usage = { ru = 0, throttled = 0, per_key = {} }
    local leases: { [string]: { holder: string, until_at: number } } = {}
    local failing: string? = nil

    local function charge(key: string, read: number, write: number): boolean
        usage.ru += read + write
        local entry = usage.per_key[key]
        if not entry then
            entry = { read = 0, write = 0 }
            usage.per_key[key] = entry
        end

        entry.read += read
        entry.write += write
        if limits and (entry.write > limits.write_per_key or entry.read > limits.read_per_key) then
            usage.throttled += 1
            return false
        end

        return true
    end

    local function read_many(prefix: string, keys: { number }): { [number]: any }
        local out = {}
        for _, key in keys do
            local name = `{prefix}{key}`
            if charge(name, 1, 0) then
                out[key] = deep.copy(data[name])
            end
        end

        return out
    end

    local ports: types.Ports = {
        shards = {
            update = function(event_id, _group, shard, transform)
                local name = `{event_id}:s{shard}`
                if failing == "shards" or not charge(name, 1, 1) then
                    return false
                end

                local current = deep.copy(data[name])
                local before = deep.copy(current)
                local new = transform(current)
                assert(deep.equal(current, before), "shard transform mutated its argument")
                if new ~= nil then
                    data[name] = deep.copy(new)
                end

                return true
            end,
            read_many = function(event_id, _group, shards)
                if failing == "read" then
                    return false, nil
                end

                return true, read_many(`{event_id}:s`, shards)
            end,
        },
        partials = {
            write = function(event_id, group, partial)
                if not charge(`{event_id}:p{group}`, 0, 1) then
                    return false
                end

                data[`{event_id}:p{group}`] = deep.copy(partial)

                return true
            end,
            read_many = function(event_id, groups)
                if failing == "partials" then
                    return false, nil
                end

                return true, read_many(`{event_id}:p`, groups)
            end,
        },
        totals = {
            read = function(event_id, replica)
                if failing == "totals" or not charge(`{event_id}:total:{replica}`, 1, 0) then
                    return false, nil
                end

                return true, deep.copy(data[`{event_id}:total:{replica}`])
            end,
            write = function(event_id, replica, snapshot)
                local name = `{event_id}:total:{replica}`
                if not charge(name, 1, 1) then
                    return false
                end

                local current = data[name]
                if current == nil or current.version <= snapshot.version then
                    data[name] = deep.copy(snapshot)
                end

                return true
            end,
            write_all = nil :: any,
        },
        lease = {
            acquire = function(event_id, role, server_id, ttl)
                local key = `{event_id}:lease:{role}`
                if not charge(key, 1, 1) then
                    return false
                end

                local current = leases[key]
                local at = clock()
                if current and current.holder ~= server_id and current.until_at > at then
                    return false
                end

                leases[key] = { holder = server_id, until_at = at + ttl }

                return true
            end,
        },
        broadcast = {
            send = function()
                return true
            end,
        },
    }

    ports.totals.write_all = function(event_id, count, snapshot)
        local written = 0
        for replica = 1, count do
            if ports.totals.write(event_id, replica, snapshot) then
                written += 1
            end
        end

        return written
    end

    local self = { ports = ports, usage = usage, data = data, leases = leases }

    function self.clear(_)
        table.clear(data)
    end

    function self.reset_window(_)
        table.clear(usage.per_key)
    end

    function self.fail(_, kind: string?)
        failing = kind
    end

    return self :: any
end

return fake
