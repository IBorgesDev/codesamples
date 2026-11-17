--!strict

local http_service = game:GetService("HttpService")

export type Result = "ok" | "retry" | "drop"
export type Transport = (body: string, events: number) -> (Result, number?)

const SUCCESS_MIN = 200
const SUCCESS_MAX = 299
const BAD_REQUEST = 400
const TOO_LARGE = 413

local transport = {}

function transport.classify(status: number): Result
    if status >= SUCCESS_MIN and status <= SUCCESS_MAX then
        return "ok"
    end

    if status == BAD_REQUEST or status == TOO_LARGE then
        return "drop"
    end

    return "retry"
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
                Url = http_service:GetSecret(url_secret):AddSuffix("/v1/batch") :: any,
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

        local headers = response.Headers or {}
        local retry_after = tonumber(headers["retry-after"] or headers["Retry-After"])

        return transport.classify(response.StatusCode), retry_after
    end
end

function transport.echo(write: (string) -> ()): Transport
    return function(body, events)
        write(`{events} events, {#body} bytes`)
        return "ok", nil
    end
end

return transport
