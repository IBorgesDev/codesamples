--!strict

local replicated_storage = game:GetService("ReplicatedStorage")
local server_script_service = game:GetService("ServerScriptService")

local deep = require(script.Parent.deep)
local protocol = require(server_script_service.Server.trade.protocol)
local tuning = require(replicated_storage.Shared.config.tuning)
local types = require(server_script_service.Server.trade.types)

type Data = types.Data
type Record = types.Record
type Side = types.Side

export type Faults = {
    record_error: number,
    lost_ack: number,
    rerun: number,
    save_fail: number,
    crash: number,
    hint_loss: number,
    duplicate: number,
    interleave: number,
    lost_settle_save: number,
}

export type Options = {
    servers: number?,
    players: number?,
    items: number?,
}

type Server = {
    id: number,
    alive: boolean,
    sessions: { [number]: Session },
}

export type Session = {
    id: number,
    user_id: number,
    server: Server,
    data: Data,
    active: boolean,
}

type Profile = {
    owner: number?,
    saved: Data,
}

type Task = { server: Server, run: () -> () }

const KINDS = { "egg_common", "egg_rare", "pet_cat", "pet_dragon" }

const STEP_SECONDS = 0.2

const MAX_INTERLEAVE_DEPTH = 3

const EVENTS = {
    { name = "run_task", chance = 0.55 },
    { name = "trade", chance = 0.25 },
    { name = "sweep", chance = 0.06 },
    { name = "autosave", chance = 0.05 },
    { name = "rejoin", chance = 0.04 },
    { name = "steal", chance = 0.02 },
    { name = "crash_random", chance = 0.01 },
}

const CRASH = table.freeze({ crash = true })

local world = {}
world.__index = world

world.NO_FAULTS = table.freeze({
    record_error = 0,
    lost_ack = 0,
    rerun = 0,
    save_fail = 0,
    crash = 0,
    hint_loss = 0,
    duplicate = 0,
    interleave = 0,
    lost_settle_save = 0,
}) :: Faults

world.CHAOS = table.freeze({
    record_error = 0.03,
    lost_ack = 0.03,
    rerun = 0.1,
    save_fail = 0.03,
    crash = 0.002,
    hint_loss = 0.05,
    duplicate = 0.1,
    interleave = 0.2,
    lost_settle_save = 0.2,
}) :: Faults

type Fields = {
    random: Random,
    faults: Faults,
    clock: number,
    records: { [string]: Record },
    profiles: { [number]: Profile },
    servers: { Server },
    online: { [number]: Session },
    tasks: { Task },
    users: { number },
    next_id: number,
    boundaries: number,
    depth: number,
    crash_at: number?,
    running: Server?,
    initial_owner: { [string]: number },
    initial_coins: { [number]: number },
    ports: types.Ports,
    stats: { [string]: number },
}

export type World = typeof(setmetatable({} :: Fields, world))

local function sorted_keys<K>(map: { [K]: any }): { K }
    local keys = {}

    for key in map do
        table.insert(keys, key)
    end

    table.sort(keys :: any)

    return keys
end

function world.new(seed: number, faults: Faults, options: Options?): World
    local opts: Options = options or {}
    local self = setmetatable(
        {
            random = Random.new(seed),
            faults = faults,
            clock = 1000,
            records = {},
            profiles = {},
            servers = {},
            online = {},
            tasks = {},
            users = {},
            next_id = 0,
            boundaries = 0,
            depth = 0,
            crash_at = nil,
            running = nil,
            initial_owner = {},
            initial_coins = {},
            ports = nil :: any,
            stats = {
                trades = 0,
                crashes = 0,
                steals = 0,
            },
        } :: Fields,
        world
    )
    self.ports = self:make_ports()

    for _ = 1, opts.servers or 3 do
        self:add_server()
    end

    for user_id = 1, opts.players or 8 do
        local data: Data = {
            coins = self.random:NextInteger(100, 1000),
            items = {},
            escrow = {},
            gift_seq = 0,
            gift_seen = {},
            outbox = {},
        }
        for n = 1, opts.items or 6 do
            local item_id = `u{user_id}i{n}`
            data.items[item_id] = { kind = KINDS[self.random:NextInteger(1, #KINDS)] }
            self.initial_owner[item_id] = user_id
        end

        self.initial_coins[user_id] = data.coins
        self.profiles[user_id] = { owner = nil, saved = data }
        table.insert(self.users, user_id)
        self:load(user_id, self.servers[(user_id - 1) % #self.servers + 1])
    end

    return self
end

function world.roll(self: World, chance: number): boolean
    return chance > 0 and self.random:NextNumber() < chance
end

function world.now(self: World): number
    self.clock += 0.001

    return self.clock
end

function world.boundary(self: World)
    self.boundaries += 1
    local running = self.running

    if running == nil then
        return
    end

    if self.boundaries == self.crash_at or self:roll(self.faults.crash) then
        error(CRASH, 0)
    end

    if self.depth < MAX_INTERLEAVE_DEPTH and self:roll(self.faults.interleave) then
        self.depth += 1
        self:run_task()
        self.depth -= 1
        self.running = running
        if not running.alive then
            error(CRASH, 0)
        end
    end
end

function world.make_ports(self: World): types.Ports
    local records: types.RecordStore = {
        update = function(tx_id, transform)
            self:boundary()
            if self:roll(self.faults.record_error) then
                return false, "throttled"
            end

            local current = deep.copy(self.records[tx_id])
            local before = deep.copy(current)

            if self:roll(self.faults.rerun) then
                transform(deep.copy(current))
            end

            local new = transform(current)
            assert(deep.equal(current, before), `transform mutated the stored record {tx_id}`)
            if new ~= nil then
                self.records[tx_id] = deep.copy(new)
            end

            local stored = deep.copy(self.records[tx_id])
            self:boundary()
            if self:roll(self.faults.lost_ack) then
                return false, "timeout"
            end

            return true, stored
        end,
        read = function(tx_id)
            self:boundary()
            if self:roll(self.faults.record_error) then
                return false, "throttled"
            end

            return true, deep.copy(self.records[tx_id])
        end,
    }

    return {
        records = records,
        now = function()
            return self:now()
        end,
        later = function(work)
            if not self:roll(self.faults.lost_settle_save) then
                work()
            end
        end,
    }
end

function world.account(self: World, session: Session): types.Account
    return {
        user_id = session.user_id,
        data = session.data,
        active = function()
            return session.active and session.server.alive
        end,
        persist = function(durable)
            self:boundary()
            local profile = self.profiles[session.user_id]

            if profile.owner ~= session.id then
                session.active = false
                return false
            end

            if self:roll(self.faults.save_fail) then
                return false
            end

            profile.saved = deep.copy(session.data)
            self:boundary()
            if self:roll(self.faults.lost_ack) then
                return false
            end

            return durable(deep.copy(profile.saved))
        end,
    }
end

function world.add_server(self: World): Server
    self.next_id += 1
    local server: Server = { id = self.next_id, alive = true, sessions = {} }
    table.insert(self.servers, server)

    return server
end

function world.random_server(self: World, except: Server?): Server?
    local choices = {}

    for _, server in self.servers do
        if server.alive and server ~= except then
            table.insert(choices, server)
        end
    end

    if #choices == 0 then
        return nil
    end

    return choices[self.random:NextInteger(1, #choices)]
end

function world.schedule(self: World, server: Server, run: () -> ())
    table.insert(self.tasks, { server = server, run = run })
end

function world.run(self: World, server: Server, fn: () -> ())
    if not server.alive then
        return
    end

    self.running = server
    local ok, err = pcall(fn :: any)
    self.running = nil
    if ok then
        return
    end

    if err == CRASH then
        self:crash(server)
    else
        error(err, 0)
    end
end

function world.crash(self: World, server: Server)
    if not server.alive then
        return
    end

    server.alive = false
    for user_id, session in server.sessions do
        session.active = false
        if self.online[user_id] == session then
            self.online[user_id] = nil
        end
    end

    table.clear(server.sessions)
    local index = table.find(self.servers, server)

    if index then
        table.remove(self.servers, index)
    end

    self.stats.crashes += 1
    self:add_server()
end

function world.load(self: World, user_id: number, server: Server): Session
    local profile = self.profiles[user_id]
    self.next_id += 1
    local session: Session = {
        id = self.next_id,
        user_id = user_id,
        server = server,
        data = deep.copy(profile.saved),
        active = true,
    }

    profile.owner = session.id
    server.sessions[user_id] = session
    self.online[user_id] = session
    self:schedule(server, function()
        protocol.recover(self.ports, self:account(session))
    end)

    return session
end

function world.release(self: World, session: Session)
    local profile = self.profiles[session.user_id]

    if session.active and session.server.alive and profile.owner == session.id then
        profile.saved = deep.copy(session.data)
        profile.owner = nil
    end

    session.active = false
    if session.server.sessions[session.user_id] == session then
        session.server.sessions[session.user_id] = nil
    end

    if self.online[session.user_id] == session then
        self.online[session.user_id] = nil
    end
end

function world.message(self: World, user_id: number, fn: (Session) -> ())
    if self:roll(self.faults.hint_loss) then
        return
    end

    local session = self.online[user_id]

    if not session then
        return
    end

    local copies = if self:roll(self.faults.duplicate) then 2 else 1

    for _ = 1, copies do
        self:schedule(session.server, function()
            fn(session)
        end)
    end
end

function world.offer(self: World, session: Session): Side
    local ids = sorted_keys(session.data.items)
    local items: types.Items = {}

    for _ = 1, self.random:NextInteger(0, math.min(3, #ids)) do
        local index = self.random:NextInteger(1, #ids)
        local item_id = table.remove(ids, index) :: string
        items[item_id] = table.clone(session.data.items[item_id])
    end

    local coins = self.random:NextInteger(0, math.min(session.data.coins, 200))

    return { user_id = session.user_id, coins = coins, items = items, ready = false }
end

function world.trade(self: World)
    local online = sorted_keys(self.online)

    if #online < 2 then
        return
    end

    local i = table.remove(online, self.random:NextInteger(1, #online)) :: number
    local j = online[self.random:NextInteger(1, #online)]
    local sa, sb = self.online[i], self.online[j]
    local a, b = self:offer(sa), self:offer(sb)
    self.next_id += 1
    local tx_id = `tx{self.next_id}`
    self.stats.trades += 1
    self:schedule(sa.server, function()
        if protocol.open(self.ports, self:account(sa), tx_id, a, b, 1) ~= "open" then
            return
        end

        self:message(j, function(session)
            if protocol.prepare(self.ports, self:account(session), tx_id) ~= "committed" then
                return
            end

            self:message(i, function(other)
                protocol.finalize(self.ports, self:account(other), tx_id)
            end)
        end)
    end)
end

function world.run_task(self: World)
    if #self.tasks == 0 then
        return
    end

    local index = self.random:NextInteger(1, #self.tasks)
    local task = self.tasks[index]
    self.tasks[index] = self.tasks[#self.tasks]
    self.tasks[#self.tasks] = nil
    self:run(task.server, task.run)
end

function world.sweep(self: World)
    local server = self:random_server()

    if not server then
        return
    end

    self:run(server, function()
        for _, user_id in sorted_keys(server.sessions) do
            protocol.recover(self.ports, self:account(server.sessions[user_id]))
        end
    end)
end

function world.autosave(self: World)
    local server = self:random_server()

    if not server then
        return
    end

    local users = sorted_keys(server.sessions)

    if #users == 0 then
        return
    end

    local session = server.sessions[users[self.random:NextInteger(1, #users)]]
    self:run(server, function()
        self:account(session).persist(function()
            return true
        end)
    end)
end

function world.rejoin(self: World)
    local user_id = self.users[self.random:NextInteger(1, #self.users)]
    local session = self.online[user_id]

    if session then
        self:release(session)
    end

    local server = self:random_server()

    if server then
        self:load(user_id, server)
    end
end

function world.steal(self: World)
    local online = sorted_keys(self.online)

    if #online == 0 then
        return
    end

    local session = self.online[online[self.random:NextInteger(1, #online)]]
    local server = self:random_server(session.server)

    if not server then
        return
    end

    self.stats.steals += 1
    self:load(session.user_id, server)
end

function world.crash_random(self: World)
    local server = self:random_server()

    if server then
        self:crash(server)
    end
end

function world.step(self: World, new_trades: boolean)
    self.clock += STEP_SECONDS
    local roll = self.random:NextNumber()

    for _, event in EVENTS do
        roll -= event.chance
        if roll < 0 then
            if event.name ~= "trade" or new_trades then
                (self :: any)[event.name](self)
            end

            return
        end
    end
end

function world.simulate(self: World, trades: number)
    while self.stats.trades < trades do
        self:step(true)
    end

    local guard = 0

    while #self.tasks > 0 and guard < 100_000 do
        self:step(false)
        guard += 1
    end
end

function world.summary(self: World): string
    local states = { open = 0, committed = 0, aborted = 0 }
    local timeouts = 0

    for _, record in self.records do
        states[record.state] += 1
        if record.reason == "timeout" then
            timeouts += 1
        end
    end

    return `{self.stats.trades} trades, {states.committed} committed, {states.aborted} aborted ({timeouts} by timeout), `
        .. `{self.stats.crashes} crashes, {self.stats.steals} steals`
end

function world.one_trade(self: World, crash_at: number?)
    table.clear(self.tasks)
    self.crash_at = crash_at
    local sa, sb = self.online[1], self.online[2]
    local function first(session: Session): types.Items
        local item_id = sorted_keys(session.data.items)[1]

        return { [item_id] = table.clone(session.data.items[item_id]) }
    end

    local a: Side = { user_id = 1, coins = 50, items = first(sa), ready = false }
    local b: Side = { user_id = 2, coins = 0, items = first(sb), ready = false }
    local opened: types.Outcome?, prepared: types.Outcome? = nil, nil
    self:run(sa.server, function()
        opened = protocol.open(self.ports, self:account(sa), "tx1", a, b, 1)
    end)

    if opened ~= "open" then
        return
    end

    self:run(sb.server, function()
        prepared = protocol.prepare(self.ports, self:account(sb), "tx1")
    end)

    if prepared ~= "committed" then
        return
    end

    self:run(sa.server, function()
        protocol.finalize(self.ports, self:account(sa), "tx1")
    end)
end

function world.escrows(self: World): number
    local count = 0

    for _, user_id in self.users do
        for _ in self.profiles[user_id].saved.escrow do
            count += 1
        end
    end

    return count
end

function world.quiesce(self: World): number
    self.faults = world.NO_FAULTS
    self.crash_at = nil
    for _, server in self.servers do
        server.alive = false
        for _, session in server.sessions do
            session.active = false
        end
    end

    self.servers = {}
    table.clear(self.online)
    table.clear(self.tasks)
    local server = self:add_server()

    for _, user_id in self.users do
        self:load(user_id, server)
    end

    table.clear(self.tasks)
    for pass = 1, 8 do
        if self:escrows() == 0 then
            return pass - 1
        end

        for _, user_id in self.users do
            protocol.recover(self.ports, self:account(self.online[user_id]))
        end

        self.clock += tuning.trade.record_timeout + tuning.trade.missing_record_grace
    end

    return math.huge
end

function world.check(self: World): { string }
    local problems = {}
    local function report(message: string)
        table.insert(problems, message)
    end

    for _, user_id in self.users do
        for tx_id in self.profiles[user_id].saved.escrow do
            report(`I4 escrow {tx_id} left on user {user_id}`)
        end
    end

    local committed: { Record } = {}

    for tx_id, record in self.records do
        if record.state == "open" then
            report(`I3 record {tx_id} still open`)
        end

        if record.state == "committed" then
            table.insert(committed, record)
        end
    end

    table.sort(committed, function(x, y)
        return (x.decided_at :: number) < (y.decided_at :: number)
    end)

    local owner = table.clone(self.initial_owner)
    local coins = table.clone(self.initial_coins)

    for _, record in committed do
        for _, pair in { { record.a, record.b }, { record.b, record.a } } do
            local from, to = pair[1], pair[2]

            for item_id in from.items do
                if owner[item_id] ~= from.user_id then
                    report(`I3 {record.tx_id}: user {from.user_id} gave {item_id}, owned by {owner[item_id]}`)
                end

                owner[item_id] = to.user_id
            end

            coins[from.user_id] -= from.coins
            coins[to.user_id] += from.coins
        end
    end

    local seen: { [string]: number } = {}

    for _, user_id in self.users do
        local data = self.profiles[user_id].saved

        if data.coins ~= coins[user_id] then
            report(`I1 user {user_id} has {data.coins} coins, expected {coins[user_id]}`)
        end

        for item_id in data.items do
            if seen[item_id] then
                report(`I2 {item_id} on users {seen[item_id]} and {user_id}`)
            end

            seen[item_id] = user_id
            if owner[item_id] ~= user_id then
                report(`I1 {item_id} on user {user_id}, expected on {owner[item_id]}`)
            end
        end
    end

    for item_id, expected in owner do
        if not seen[item_id] then
            report(`I1 {item_id} lost, expected on user {expected}`)
        end
    end

    local before = deep.copy({ records = self.records, profiles = self.profiles })

    for _ = 1, 3 do
        for _, user_id in self.users do
            protocol.recover(self.ports, self:account(self.online[user_id]))
        end
    end

    if not deep.equal(before, { records = self.records, profiles = self.profiles }) then
        report("I5 recovery changed a settled world")
    end

    return problems
end

return world
