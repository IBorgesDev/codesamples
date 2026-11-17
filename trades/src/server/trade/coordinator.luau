--!strict

local memory_store_service = game:GetService("MemoryStoreService")
local messaging_service = game:GetService("MessagingService")
local replicated_storage = game:GetService("ReplicatedStorage")

local hash = require(replicated_storage.Shared.util.hash)
local memory_gate = require(script.Parent.Parent.net.memory_gate)
local negotiation = require(script.Parent.negotiation)

export type Shared = {
    session: negotiation.Session,
    servers: { a: string, b: string },
    rev: number,
    tx_id: string?,
    locked_at: number?,
    opened: boolean?,
    outcome: string?,
    reason: string?,
}

export type Message = {
    kind: string,
    session: string?,
    from: number?,
    to: number?,
    server: string?,
    accept: boolean?,
}

export type Change = (shared: Shared) -> (boolean, string?)

export type Coordinator = {
    presence_set: (user_id: number, server_id: string) -> boolean,
    presence_clear: (user_id: number, server_id: string) -> boolean,
    presence_get: (user_id: number) -> (boolean, string?),
    create: (shared: Shared) -> boolean,
    change: (session_id: string, change: Change) -> (boolean, Shared?, string?),
    get: (session_id: string) -> (boolean, Shared?),
    send: (server_id: string, message: Message) -> boolean,
}

export type Options = {
    map_name: string,
    maps: number,
    presence_ttl: number,
    session_ttl: number,
    backoff_base: number,
    backoff_cap: number,
}

local coordinator = {}

function coordinator.topic(server_id: string): string
    return `trade:{server_id}`
end

local function copy<T>(value: T): T
    if type(value) ~= "table" then
        return value
    end

    local out = {}
    for key, item in value :: any do
        out[key] = copy(item)
    end

    return out :: any
end

function coordinator.change_transform(change: Change, result: { why: string? }): (Shared?) -> Shared?
    return function(current)
        if current == nil then
            result.why = "missing"
            return nil
        end

        local next_shared = copy(current)
        local ok, why = change(next_shared)
        result.why = why
        if not ok then
            return nil
        end

        next_shared.rev = current.rev + 1

        return next_shared
    end
end

function coordinator.memory_store(options: Options): Coordinator
    local maps: { MemoryStoreHashMap } = {}
    for index = 1, options.maps do
        maps[index] = memory_store_service:GetHashMap(`{options.map_name}:{index}`)
    end

    local call = memory_gate.new(options.backoff_base, options.backoff_cap)

    local function map(key: string): MemoryStoreHashMap
        return maps[hash.bucket(key, options.maps)]
    end

    return {
        presence_set = function(user_id, server_id)
            local ok = call(function()
                local key = `u:{user_id}`
                map(key):SetAsync(key, server_id, options.presence_ttl)
            end)

            return ok
        end,
        presence_clear = function(user_id, server_id)
            local ok = call(function()
                local key = `u:{user_id}`
                map(key):UpdateAsync(key, function(current: string?): string?
                    if current ~= server_id then
                        return nil
                    end

                    return ""
                end, 1)
            end)

            return ok
        end,
        presence_get = function(user_id)
            local ok, server = call(function()
                local key = `u:{user_id}`
                return map(key):GetAsync(key)
            end)

            if not ok then
                return false, nil
            end

            return true, if server == "" then nil else server
        end,
        create = function(shared)
            local ok = call(function()
                local key = `s:{shared.session.id}`
                map(key):SetAsync(key, shared, options.session_ttl)
            end)

            return ok
        end,
        change = function(session_id, change)
            local result: { why: string? } = { why = nil }
            local ok, stored = call(function()
                local key = `s:{session_id}`
                return map(key):UpdateAsync(
                    key,
                    coordinator.change_transform(change, result) :: any,
                    options.session_ttl
                )
            end)

            if not ok then
                return false, nil, "store_error"
            end

            if stored == nil then
                return false, nil, result.why
            end

            return true, stored, nil
        end,
        get = function(session_id)
            return call(function()
                local key = `s:{session_id}`
                return map(key):GetAsync(key)
            end)
        end,
        send = function(server_id, message)
            local ok = pcall(function()
                messaging_service:PublishAsync(coordinator.topic(server_id), message)
            end)

            return ok
        end,
    }
end

function coordinator.subscribe(server_id: string, handler: (Message) -> ()): RBXScriptConnection?
    local ok, connection = pcall(function()
        return messaging_service:SubscribeAsync(coordinator.topic(server_id), function(packet)
            if type(packet.Data) == "table" then
                handler(packet.Data)
            end
        end)
    end)

    return if ok then connection else nil
end

return coordinator
