--!strict

local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")

local token_bucket = require(script.Parent.token_bucket)
local tuning = require(replicated_storage.Shared.config.tuning)

export type Pace = { rate: number, burst: number }

export type Stray = "malformed" | "flood"

export type ToServer<T...> = {
    pace: Pace,
    fire: (self: ToServer<T...>, T...) -> boolean,
    on: (self: ToServer<T...>, handler: (player: Player, ...unknown) -> ()) -> RBXScriptConnection,
}

export type ToClient<T...> = {
    fire: (self: ToClient<T...>, player: Player, T...) -> (),
    on: (self: ToClient<T...>, handler: (T...) -> ()) -> RBXScriptConnection,
}

export type State<T> = {
    set: (self: State<T>, player: Player, value: T) -> (),
    observe: (self: State<T>, fn: (value: T) -> ()) -> () -> (),
}

local remote = {}

const SELF = "self"

local buckets: { [Pace]: token_bucket.Limiter } = {}
local report_stray: ((player: Player, path: string, stray: Stray) -> ())? = nil

local function paced(pace: Pace): boolean
    local bucket = buckets[pace]
    if bucket == nil then
        bucket = token_bucket.new(pace.rate, pace.burst)
        buckets[pace] = bucket
    end

    return bucket:take(SELF)
end

local function stray(player: Player, path: string, kind: Stray)
    if report_stray and player.Parent == players then
        report_stray(player, path, kind)
    end
end

local function instance(folder: Instance, name: string, create: boolean): RemoteEvent
    local existing = folder:FindFirstChild(name)
    if existing then
        assert(existing:IsA("RemoteEvent"), `[net] {name} is a {existing.ClassName}, expected a RemoteEvent`)
        return existing
    end

    if not create then
        return folder:WaitForChild(name) :: RemoteEvent
    end

    local event = Instance.new("RemoteEvent")
    event.Name = name
    event.Parent = folder

    return event
end

local function server_to_client(folder: Instance, path: string, create: boolean): RemoteEvent
    local event = instance(folder, path, create)
    if create then
        event.OnServerEvent:Connect(function(player)
            stray(player, path, "malformed")
        end)
    end

    return event
end

function remote.on_stray(report: (player: Player, path: string, stray: Stray) -> ())
    report_stray = report
end

function remote.to_server<T...>(pace: Pace?): ToServer<T...>
    local event: RemoteEvent = nil :: any
    local def = {}
    def.pace = pace or tuning.net.default_pace
    function def._bind(folder: Instance, path: string, create: boolean)
        event = instance(folder, path, create)
    end

    function def.fire(_, ...)
        if not (paced(def.pace) and paced(tuning.net.global_pace)) then
            return false
        end

        event:FireServer(...)

        return true
    end

    function def.on(_, handler)
        return event.OnServerEvent:Connect(handler)
    end

    return def :: any
end

function remote.to_client<T...>(): ToClient<T...>
    local event: RemoteEvent = nil :: any
    local def = {}
    function def._bind(folder: Instance, path: string, create: boolean)
        event = server_to_client(folder, path, create)
    end

    function def.fire(_, player: Player, ...)
        event:FireClient(player, ...)
    end

    function def.on(_, handler)
        return event.OnClientEvent:Connect(handler)
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

    local function serve_sync(path: string, player: Player, ...: unknown)
        if player.Parent ~= players then
            return
        end

        if select("#", ...) > 0 then
            stray(player, path, "malformed")
            return
        end

        local now = os.clock()
        if now - (last_sync[player] or -math.huge) < tuning.net.sync_cooldown then
            stray(player, path, "flood")
            return
        end

        last_sync[player] = now
        local entry = last[player]
        if entry then
            push:FireClient(player, entry.seq, entry.value)
        end
    end

    local function receive(seq: number, value: T)
        if seq <= newest then
            return
        end

        newest = seq
        current = value
        for _, fn in observers do
            task.spawn(fn, value)
        end
    end

    local def = {}
    function def._bind(folder: Instance, path: string, create: boolean)
        push = server_to_client(folder, `{path}.push`, create)
        sync = instance(folder, `{path}.sync`, create)
        if not create then
            push.OnClientEvent:Connect(receive)
            return
        end

        sync.OnServerEvent:Connect(function(player: Player, ...: unknown)
            serve_sync(`{path}.sync`, player, ...)
        end)

        players.PlayerRemoving:Connect(function(player)
            last[player] = nil
            last_sync[player] = nil
        end)
    end

    function def.set(_, player: Player, value: T)
        state_seq += 1
        last[player] = { seq = state_seq, value = value }
        push:FireClient(player, state_seq, value)
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
