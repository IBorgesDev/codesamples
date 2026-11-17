--!strict

local memory_store_service = game:GetService("MemoryStoreService")
local messaging_service = game:GetService("MessagingService")

local memory_gate = require(script.Parent.Parent.net.memory_gate)
local stats = require(script.Parent.Parent.dev.stats)
local types = require(script.Parent.types)

export type Options = {
    expiration: number,
    read_parallelism: number,
    backoff_base: number,
    backoff_cap: number,
}

local memory_store = {}

function memory_store.topic(event_id: string): string
    return `live:{event_id}`
end

function memory_store.ports(options: Options): types.Ports
    local maps: { [string]: MemoryStoreHashMap } = {}
    local call = memory_gate.new(options.backoff_base, options.backoff_cap, function(message)
        stats("live.memory_store_error", message)
    end)

    local function map(name: string): MemoryStoreHashMap
        local existing = maps[name]
        if existing then
            return existing
        end

        local created = memory_store_service:GetHashMap(name)
        maps[name] = created

        return created
    end

    local function read_many(
        hash_map: MemoryStoreHashMap,
        keys: { number },
        key_name: (number) -> string
    ): (boolean, { [number]: any }?)
        local out: { [number]: any } = {}
        local failed = false
        local cursor = 0
        local workers = math.min(options.read_parallelism, #keys)
        local active = workers

        for _ = 1, workers do
            task.spawn(function()
                while not failed do
                    cursor += 1
                    local key = keys[cursor]
                    if key == nil then
                        break
                    end

                    local ok, value = call(function()
                        return hash_map:GetAsync(key_name(key))
                    end)

                    if not ok then
                        failed = true
                        break
                    end

                    out[key] = value
                end

                active -= 1
            end)
        end

        while active > 0 do
            task.wait()
        end

        if failed then
            return false, nil
        end

        return true, out
    end

    local function shard_key(shard: number): string
        return `s:{shard}`
    end

    local function partial_key(group: number): string
        return `p:{group}`
    end

    local shards: types.ShardStore = {
        update = function(event_id, group, shard, transform)
            local ok = call(function()
                map(`live:{event_id}:g{group}`):UpdateAsync(shard_key(shard), transform :: any, options.expiration)
            end)

            return ok
        end,
        read_many = function(event_id, group, wanted)
            return read_many(map(`live:{event_id}:g{group}`), wanted, shard_key)
        end,
    }

    local partials: types.PartialStore = {
        write = function(event_id, group, partial)
            local ok = call(function()
                map(`live:{event_id}:root`):SetAsync(partial_key(group), partial, options.expiration)
            end)

            return ok
        end,
        read_many = function(event_id, wanted)
            return read_many(map(`live:{event_id}:root`), wanted, partial_key)
        end,
    }

    local function read_total(event_id: string, replica: number): (boolean, types.Snapshot?)
        return call(function()
            return map(`live:{event_id}:meta`):GetAsync(`total:{replica}`)
        end)
    end

    local function write_total(event_id: string, replica: number, snapshot: types.Snapshot): boolean
        local ok = call(function()
            map(`live:{event_id}:meta`):UpdateAsync(
                `total:{replica}`,
                function(current: types.Snapshot?): types.Snapshot?
                    if current and current.version > snapshot.version then
                        return nil
                    end

                    return snapshot
                end,
                options.expiration
            )
        end)

        return ok
    end

    local function write_all(event_id: string, count: number, snapshot: types.Snapshot): number
        local written = 0
        local pending = count
        for replica = 1, count do
            task.spawn(function()
                if write_total(event_id, replica, snapshot) then
                    written += 1
                end

                pending -= 1
            end)
        end

        while pending > 0 do
            task.wait()
        end

        return written
    end

    local lease: types.Lease = {
        acquire = function(event_id, role, server_id, ttl)
            local ok, holder = call(function()
                return map(`live:{event_id}:meta`):UpdateAsync(`lease:{role}`, function(current: string?): string?
                    if current ~= nil and current ~= server_id then
                        return nil
                    end

                    return server_id
                end, math.ceil(ttl))
            end)

            return ok and holder == server_id
        end,
    }

    local broadcast: types.Broadcast = {
        send = function(event_id, snapshot)
            local ok = pcall(function()
                messaging_service:PublishAsync(memory_store.topic(event_id), snapshot)
            end)

            return ok
        end,
    }

    return {
        shards = shards,
        partials = partials,
        totals = { read = read_total, write = write_total, write_all = write_all },
        lease = lease,
        broadcast = broadcast,
    }
end

function memory_store.subscribe(event_id: string, on_snapshot: (types.Snapshot) -> ()): RBXScriptConnection?
    local ok, connection = pcall(function()
        return messaging_service:SubscribeAsync(memory_store.topic(event_id), function(message)
            if type(message.Data) == "table" then
                on_snapshot(message.Data)
            end
        end)
    end)

    return if ok then connection else nil
end

return memory_store
