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

export type Outbox = {
    capacity: number,
    events: { [number]: Event },
    first: number,
    last: number,
    dropped: number,
    seq: number,
    pending: Batch?,
    retry_at: number,
}

local outbox = {}

function outbox.new(capacity: number): Outbox
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

function outbox.size(self: Outbox): number
    return self.last - self.first + 1
end

function outbox.empty(self: Outbox): boolean
    return self.pending == nil and outbox.size(self) == 0 and self.dropped == 0
end

function outbox.push(self: Outbox, event: Event)
    if outbox.size(self) >= self.capacity then
        self.events[self.first] = nil
        self.first += 1
        self.dropped += 1
    end

    self.last += 1
    self.events[self.last] = event
end

function outbox.ready(self: Outbox, now: number): boolean
    return now >= self.retry_at and not outbox.empty(self)
end

function outbox.retrying(self: Outbox): boolean
    return self.pending ~= nil
end

function outbox.take(self: Outbox, max_events: number, now: number): Batch?
    local pending = self.pending
    if pending then
        return pending
    end

    local count = math.min(max_events, outbox.size(self))
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

function outbox.expired(batch: Batch, now: number, max_age: number): boolean
    return now - batch.created_at > max_age
end

function outbox.settle(self: Outbox, batch: Batch)
    if self.pending == batch then
        self.pending = nil
        self.retry_at = 0
    end
end

function outbox.retry_in(self: Outbox, batch: Batch, now: number, delay: number)
    if self.pending == batch then
        batch.attempts += 1
        self.retry_at = now + delay
    end
end

function outbox.retry_now(self: Outbox)
    self.retry_at = 0
end

return outbox
