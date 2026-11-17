--!strict

local http_service = game:GetService("HttpService")

local http_budget = require(script.Parent.Parent.net.http_budget)
local parse = require(script.Parent.parse)
local types = require(script.Parent.types)

const CONSUMER = "live_event"
const ONE_COPY = 1

export type Options = {
    url_secret: string,
    token_secret: string,
}

local http = {}

local function wire_entry(entry: types.Entry): { [string]: types.Tally }
    local out = {}
    if next(entry.plus) then
        out.plus = entry.plus
    end

    if next(entry.minus) then
        out.minus = entry.minus
    end

    return out
end

local function snapshot_from(wire: unknown, now: number): types.Snapshot?
    if type(wire) ~= "table" then
        return nil
    end

    local received = table.clone(wire :: { [string]: unknown })
    received.replicas = ONE_COPY
    received.at = now

    return parse.snapshot(received)
end

function http.backend(options: Options, clock: () -> number): types.Backend
    local function request(path: string, body: any, urgent: boolean): (types.Published, unknown)
        if not urgent and not http_budget.take(CONSUMER) then
            return "throttled", nil
        end

        local ok, response = pcall(function()
            local url = http_service:GetSecret(options.url_secret):AddSuffix(path)
            local token = http_service:GetSecret(options.token_secret):AddPrefix("Bearer ")
            return http_service:RequestAsync({
                Url = url :: any,
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json", Authorization = token :: any },
                Body = http_service:JSONEncode(body),
            })
        end)

        if not ok or not response.Success then
            return "failed", nil
        end

        local decoded, answer = pcall(function()
            return http_service:JSONDecode(response.Body)
        end)

        return if decoded then "sent" else "failed", answer
    end

    return {
        publish = function(server_id, entries, urgent)
            local events = {}
            for event_id, entry in entries do
                events[event_id] = wire_entry(entry)
            end

            local path = if urgent then "/v1/publish?sync=1" else "/v1/publish"
            local published: types.Published, answer = request(path, { server = server_id, events = events }, urgent)
            local stored = if type(answer) == "table" then (answer :: { [string]: unknown }).events else nil
            if published ~= "sent" then
                return published, {}
            end

            if type(stored) ~= "table" then
                return "failed", {}
            end

            local now = clock()
            local landed: { [string]: types.Snapshot } = {}
            for event_id in entries do
                local snapshot = snapshot_from((stored :: { [string]: unknown })[event_id], now)
                if snapshot then
                    landed[event_id] = snapshot
                end
            end

            return "sent", landed
        end,
    }
end

return http
