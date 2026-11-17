--!strict

export type Event = {
    name: string,
    at: number,
    user_id: number?,
    session_id: string?,
    weight: number,
    props: { [string]: any },
}

export type Batch = {
    seq: number,
    events: { Event },
    dropped: number,
    attempts: number,
    created_at: number,
}

export type Buffer = {
    capacity: number,
    events: { [number]: Event },
    first: number,
    last: number,
    dropped: number,
    seq: number,
    pending: Batch?,
    retry_at: number,
}

local buffer = {}

function buffer.new(capacity: number): Buffer
    return {
        capacity = capacity,
        events = {},
        first = 1,
        last = 0,
        dropped = 0,
        seq = 0,
        pending = nil,
        retry_at = 0,
    }
end

function buffer.size(self: Buffer): number
    return self.last - self.first + 1
end

function buffer.push(self: Buffer, event: Event)
    if buffer.size(self) >= self.capacity then
        self.events[self.first] = nil
        self.first += 1
        self.dropped += 1
    end

    self.last += 1
    self.events[self.last] = event
end

function buffer.ready(self: Buffer, now: number): boolean
    return now >= self.retry_at and (self.pending ~= nil or buffer.size(self) > 0 or self.dropped > 0)
end

function buffer.take(self: Buffer, max_events: number, now: number): Batch?
    local pending = self.pending
    if pending then
        return pending
    end

    local count = math.min(max_events, buffer.size(self))
    if count == 0 and self.dropped == 0 then
        return nil
    end

    local events = {}
    for index = self.first, self.first + count - 1 do
        table.insert(events, self.events[index])
        self.events[index] = nil
    end

    self.first += count
    self.seq += 1
    local batch: Batch = { seq = self.seq, events = events, dropped = self.dropped, attempts = 0, created_at = now }
    self.dropped = 0
    self.pending = batch

    return batch
end

function buffer.expired(self: Buffer, now: number, max_age: number): boolean
    local pending = self.pending

    return pending ~= nil and now - pending.created_at > max_age
end

function buffer.acked(self: Buffer)
    self.pending = nil
    self.retry_at = 0
end

function buffer.failed(self: Buffer, now: number, delay: number)
    local pending = self.pending
    if pending then
        pending.attempts += 1
    end

    self.retry_at = now + delay
end

return buffer
