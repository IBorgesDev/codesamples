--!strict

local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")

local tuning = require(replicated_storage.Shared.config.tuning)

export type Kind = "reliable" | "unreliable"

export type ToServer<T...> = {
    fire: (self: ToServer<T...>, T...) -> (),
    on: (self: ToServer<T...>, handler: (player: Player, ...unknown) -> ()) -> RBXScriptConnection,
}

export type ToClient<T...> = {
    fire: (self: ToClient<T...>, player: Player, T...) -> (),
    fire_list: (self: ToClient<T...>, targets: { Player }, T...) -> (),
    fire_all: (self: ToClient<T...>, T...) -> (),
    on: (self: ToClient<T...>, handler: (T...) -> ()) -> RBXScriptConnection,
}

export type Request<R, A...> = {
    call: (self: Request<R, A...>, A...) -> (boolean, R | string),
    handle: (self: Request<R, A...>, handler: (player: Player, ...unknown) -> R) -> (),
}

export type State<T> = {
    set: (self: State<T>, player: Player, value: T) -> (),
    get: (self: State<T>, player: Player) -> T?,
    clear: (self: State<T>, player: Player) -> (),
    observe: (self: State<T>, fn: (value: T) -> ()) -> () -> (),
}

local remote = {}

remote.REJECTED = table.freeze({ rejected = true })

local function instance(folder: Instance, name: string, kind: Kind, create: boolean): RemoteEvent
    local class = if kind == "unreliable" then "UnreliableRemoteEvent" else "RemoteEvent"
    local existing = folder:FindFirstChild(name)

    if existing then
        assert(existing.ClassName == class, `[net] {name} is a {existing.ClassName}, expected {class}`)
        return existing :: any
    end

    if not create then
        return folder:WaitForChild(name) :: any
    end

    local event = Instance.new(class)
    event.Name = name
    event.Parent = folder

    return event :: any
end

function remote.to_server<T...>(kind: Kind?): ToServer<T...>
    local event: RemoteEvent = nil :: any
    local def = {}
    function def._bind(folder: Instance, path: string, create: boolean)
        event = instance(folder, path, kind or "reliable", create)
    end

    function def.fire(_, ...)
        event:FireServer(...)
    end

    function def.on(_, handler)
        return event.OnServerEvent:Connect(handler)
    end

    return def :: any
end

function remote.to_client<T...>(kind: Kind?): ToClient<T...>
    local event: RemoteEvent = nil :: any
    local def = {}
    function def._bind(folder: Instance, path: string, create: boolean)
        event = instance(folder, path, kind or "reliable", create)
    end

    function def.fire(_, player: Player, ...)
        event:FireClient(player, ...)
    end

    function def.fire_list(_, targets: { Player }, ...)
        for _, player in targets do
            event:FireClient(player, ...)
        end
    end

    function def.fire_all(_, ...)
        event:FireAllClients(...)
    end

    function def.on(_, handler)
        return event.OnClientEvent:Connect(handler)
    end

    return def :: any
end

local function valid_request_id(id: unknown): boolean
    return type(id) == "number" and id == id and id % 1 == 0 and id > 0 and id < 2 ^ 31
end

function remote.respond(
    handler: (Player, ...unknown) -> any,
    player: Player,
    id: unknown,
    ...: unknown
): (boolean?, any)
    if not valid_request_id(id) then
        return nil, nil
    end

    local ok, value = pcall(handler, player, ...)

    if not ok then
        warn(`[net] request handler failed: {value}`)
        return false, "internal"
    end

    if value == remote.REJECTED then
        return false, "rejected"
    end

    return true, value
end

local next_request_id = 0

function remote.request<R, A...>(timeout: number?): Request<R, A...>
    local req: RemoteEvent = nil :: any
    local res: RemoteEvent = nil :: any
    local pending: { [number]: thread } = {}
    local def = {}
    function def._bind(folder: Instance, path: string, create: boolean)
        req = instance(folder, `{path}.req`, "reliable", create)
        res = instance(folder, `{path}.res`, "reliable", create)
        if not create then
            res.OnClientEvent:Connect(function(id: number, ok: boolean, value: any)
                local thread = pending[id]

                if not thread then
                    return
                end

                pending[id] = nil
                task.spawn(thread, ok, value)
            end)
        end
    end

    function def.call(_, ...)
        next_request_id += 1
        local id = next_request_id
        pending[id] = coroutine.running()
        req:FireServer(id, ...)
        task.delay(timeout or tuning.net.request_timeout, function()
            local thread = pending[id]

            if not thread then
                return
            end

            pending[id] = nil
            task.spawn(thread, false, "timeout")
        end)

        return coroutine.yield()
    end

    function def.handle(_, handler)
        req.OnServerEvent:Connect(function(player: Player, id: unknown, ...: unknown)
            local ok, value = remote.respond(handler, player, id, ...)

            if ok ~= nil and player.Parent == players then
                res:FireClient(player, id, ok, value)
            end
        end)
    end

    return def :: any
end

local state_seq = 0

function remote.state<T>(): State<T>
    local push: RemoteEvent = nil :: any
    local sync: RemoteEvent = nil :: any
    local last: { [Player]: { seq: number, value: T } } = {}
    local last_sync: { [Player]: number } = {}
    local newest = 0
    local current: T? = nil
    local observers: { [{}]: (T) -> () } = {}
    local asked = false

    local def = {}
    function def._bind(folder: Instance, path: string, create: boolean)
        push = instance(folder, `{path}.push`, "reliable", create)
        sync = instance(folder, `{path}.sync`, "reliable", create)
        if create then
            sync.OnServerEvent:Connect(function(player: Player)
                local now = os.clock()

                if now - (last_sync[player] or -math.huge) < tuning.net.sync_cooldown then
                    return
                end

                last_sync[player] = now
                local entry = last[player]

                if entry then
                    push:FireClient(player, entry.seq, entry.value)
                end
            end)

            players.PlayerRemoving:Connect(function(player)
                last[player] = nil
                last_sync[player] = nil
            end)
        else
            push.OnClientEvent:Connect(function(seq: number, value: T)
                if seq <= newest then
                    return
                end

                newest = seq
                current = value
                for _, fn in observers do
                    task.spawn(fn, value)
                end
            end)
        end
    end

    function def.set(_, player: Player, value: T)
        state_seq += 1
        last[player] = { seq = state_seq, value = value }
        push:FireClient(player, state_seq, value)
    end

    function def.get(_, player: Player): T?
        local entry = last[player]

        return entry and entry.value
    end

    function def.clear(_, player: Player)
        last[player] = nil
    end

    function def.observe(_, fn: (T) -> ())
        local key = {}
        observers[key] = fn
        if current ~= nil then
            task.spawn(fn, current :: T)
        end

        if not asked then
            asked = true
            sync:FireServer()
        end

        return function()
            observers[key] = nil
        end
    end

    return def :: any
end

local function is_definition(value: any): boolean
    return type(value) == "table" and type(value._bind) == "function"
end

function remote.build(tree: { [string]: any }, folder: Instance, create: boolean, prefix: string?)
    for key, value in tree do
        local path = if prefix then `{prefix}.{key}` else key

        if is_definition(value) then
            value._bind(folder, path, create)
        elseif type(value) == "table" then
            remote.build(value, folder, create, path)
        else
            error(`[net] {path} is not a remote definition`)
        end
    end
end

return remote
