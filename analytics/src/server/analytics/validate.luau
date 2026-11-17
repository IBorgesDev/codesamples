--!strict

local buffer = require(script.Parent.buffer)

const MAX_SAFE_INTEGER = 2 ^ 53

export type Definition = {
    props: { [string]: string },
    sample: number?,
}

export type Schema = {
    version: number,
    limits: {
        string_bytes: number,
        server_id_bytes: number,
        session_id_bytes: number,
        batch_events: number,
        batch_bytes: number,
        max_weight: number,
    },
    events: { [string]: Definition },
}

local validate = {}

local function finite(value: any): boolean
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value: any): boolean
    return finite(value) and value % 1 == 0 and math.abs(value) <= MAX_SAFE_INTEGER
end

local function matches(kind: string, value: any, schema: Schema): boolean
    if kind == "string" then
        return type(value) == "string" and #value <= schema.limits.string_bytes and utf8.len(value) ~= nil
    end

    if kind == "number" then
        return finite(value)
    end

    if kind == "integer" then
        return integer(value)
    end

    if kind == "boolean" then
        return type(value) == "boolean"
    end

    return false
end

function validate.event(schema: Schema, event: buffer.Event): (boolean, string?)
    local definition = schema.events[event.name]
    if definition == nil then
        return false, "unknown_event"
    end

    if not finite(event.at) then
        return false, "at"
    end

    if not finite(event.weight) or event.weight < 1 or event.weight > schema.limits.max_weight then
        return false, "weight"
    end

    if event.user_id ~= nil and not (integer(event.user_id) and event.user_id >= 0) then
        return false, "user_id"
    end

    local session_id = event.session_id
    if session_id ~= nil and (type(session_id) ~= "string" or #session_id > schema.limits.session_id_bytes) then
        return false, "session_id"
    end

    if type(event.props) ~= "table" then
        return false, "props"
    end

    for prop, kind in definition.props do
        local value = event.props[prop]
        if value == nil then
            return false, `missing:{prop}`
        end

        if not matches(kind, value, schema) then
            return false, `type:{prop}`
        end
    end

    for prop in event.props do
        if definition.props[prop] == nil then
            return false, `extra:{prop}`
        end
    end

    return true, nil
end

function validate.weight(definition: Definition?): number
    local sample = if definition then definition.sample else nil

    return if sample and sample > 0 then math.round(1 / sample) else 1
end

return validate
