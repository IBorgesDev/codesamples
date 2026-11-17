--!strict

local http_service = game:GetService("HttpService")

export type Result = "ok" | "retry" | "drop"
export type Transport = (body: string, events: number) -> (Result, number?)

const SUCCESS_MIN = 200
const SUCCESS_MAX = 299
const BAD_REQUEST = 400
const TOO_LARGE = 413
const BATCH_PATH = "/v1/batch"

local transport = {}

local function classify(status: number): Result
    if status >= SUCCESS_MIN and status <= SUCCESS_MAX then
        return "ok"
    end

    if status == BAD_REQUEST or status == TOO_LARGE then
        return "drop"
    end

    return "retry"
end

local function retry_after(headers: { [string]: string }): number?
    local seconds = tonumber(headers["retry-after"] or headers["Retry-After"])
    if seconds == nil or seconds ~= seconds or seconds < 0 or seconds == math.huge then
        return nil
    end

    return seconds
end

function transport.http(url_secret: string, token_secret: string): Transport?
    local ok = pcall(function()
        http_service:GetSecret(url_secret)
        http_service:GetSecret(token_secret)
    end)

    if not ok then
        return nil
    end

    return function(body)
        local sent, response = pcall(function()
            return http_service:RequestAsync({
                Url = http_service:GetSecret(url_secret):AddSuffix(BATCH_PATH) :: any,
                Method = "POST",
                Headers = {
                    ["Content-Type"] = "application/json",
                    Authorization = http_service:GetSecret(token_secret):AddPrefix("Bearer ") :: any,
                },
                Body = body,
            })
        end)

        if not sent then
            return "retry", nil
        end

        return classify(response.StatusCode), retry_after(response.Headers or {})
    end
end

function transport.echo(write: (string) -> ()): Transport
    return function(body, events)
        write(`{events} events, {#body} bytes`)

        return "ok", nil
    end
end

return transport
