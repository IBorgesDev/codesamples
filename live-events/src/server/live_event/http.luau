--!strict

local http_service = game:GetService("HttpService")

local http_budget = require(script.Parent.Parent.net.http_budget)
local types = require(script.Parent.types)

const CONSUMER = "live_event"

export type Options = {
    url_secret: string,
    token_secret: string,
}

local http = {}

function http.wire_entry(entry: types.Entry): { [string]: types.Tally }
    local out = {}
    if next(entry.plus) then
        out.plus = entry.plus
    end

    if next(entry.minus) then
        out.minus = entry.minus
    end

    return out
end

function http.snapshot(wire: any, now: number): types.Snapshot
    return {
        state = wire.state,
        version = wire.version,
        totals = if type(wire.totals) == "table" then wire.totals else {},
        completed_at = wire.completed_at,
        ends_at = wire.ends_at,
        servers = wire.servers or 0,
        replicas = 1,
        at = now,
    }
end

function http.backend(options: Options, clock: () -> number): types.Backend
    local function request(method: string, path: string, body: any?): (boolean, any)
        if not http_budget.take(CONSUMER) then
            return false, "budget"
        end

        local ok, response = pcall(function()
            local url = http_service:GetSecret(options.url_secret):AddSuffix(path)
            local token = http_service:GetSecret(options.token_secret):AddPrefix("Bearer ")
            return http_service:RequestAsync({
                Url = url :: any,
                Method = method,
                Headers = { ["Content-Type"] = "application/json", Authorization = token :: any },
                Body = if body ~= nil then http_service:JSONEncode(body) else nil,
            })
        end)

        if not ok then
            return false, response
        end

        if not response.Success then
            return false, response.StatusCode
        end

        return pcall(function()
            return http_service:JSONDecode(response.Body)
        end)
    end

    return {
        publish = function(server_id, entries, sync)
            local events = {}
            for event_id, entry in entries do
                events[event_id] = http.wire_entry(entry)
            end

            local path = if sync then "/v1/publish?sync=1" else "/v1/publish"
            local ok, body = request("POST", path, { server = server_id, events = events })
            if not ok or type(body) ~= "table" or type(body.events) ~= "table" then
                return false, nil
            end

            local now = clock()
            local snapshots = {}
            for event_id, wire in body.events do
                snapshots[event_id] = http.snapshot(wire, now)
            end

            return true, snapshots
        end,
        read = function(event_id)
            local ok, body = request("GET", `/v1/events/{event_id}`, nil)
            if not ok or type(body) ~= "table" then
                return false, nil
            end

            return true, http.snapshot(body, clock())
        end,
    }
end

return http
