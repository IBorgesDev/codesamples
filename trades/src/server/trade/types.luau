--!strict

export type Item = { kind: string }
export type Items = { [string]: Item }

export type Role = "a" | "b"

export type Side = {
    user_id: number,
    coins: number,
    items: Items,
    ready: boolean,
}

export type RecordState = "open" | "committed" | "aborted"

export type Record = {
    tx_id: string,
    state: RecordState,
    a: Side,
    b: Side,
    offer_version: number,
    created_at: number,
    decided_at: number?,
    reason: string?,
    tombstone: boolean?,
}

export type Escrow = {
    role: Role,
    coins: number,
    items: Items,
    at: number,
}

export type Outgoing = {
    to: number,
    from: number,
    seq: number,
    coins: number,
    items: Items,
    at: number,
    sends: number?,
}

export type Data = {
    coins: number,
    items: Items,
    escrow: { [string]: Escrow },
    gift_seq: number,
    gift_seen: { [string]: number },
    outbox: { [string]: Outgoing },
}

export type RecordStore = {
    update: (tx_id: string, transform: (current: Record?) -> Record?) -> (boolean, any),
    read: (tx_id: string) -> (boolean, any),
}

export type Account = {
    user_id: number,
    data: Data,
    active: () -> boolean,
    persist: (durable: (saved: Data) -> boolean) -> boolean,
}

export type Ports = {
    records: RecordStore,
    now: () -> number,
    later: (work: () -> ()) -> (),
}

export type Outcome = "open" | "committed" | "aborted" | "pending" | "refused"

return {}
