import type { Catalog, PropType } from "./catalog.js";

export type PropValue = string | number | boolean;

export type TrackedEvent = {
  name: string;
  at: number;
  user_id?: number;
  session_id?: string;
  weight: number;
  props: Record<string, PropValue>;
};

export type Envelope = {
  server_id: string;
  place_id: number;
  place_version: number;
  batch_seq: number;
  sent_at: number;
  dropped: number;
  events: unknown[];
};

export type EnvelopeError =
  | "not_object"
  | "schema"
  | "server_id"
  | "place_id"
  | "place_version"
  | "batch_seq"
  | "sent_at"
  | "dropped"
  | "events"
  | "too_many_events";

export type EventRejection =
  | "not_object"
  | "unknown_event"
  | "at"
  | "user_id"
  | "session_id"
  | "weight"
  | "props"
  | "missing_prop"
  | "extra_prop"
  | "wrong_type"
  | "not_finite"
  | "integer_expected"
  | "string_too_long"
  | "stale"
  | "ahead";

export type EnvelopeResult = { ok: true; envelope: Envelope } | { ok: false; reason: EnvelopeError };

export type EventResult = { ok: true; event: TrackedEvent } | { ok: false; reason: EventRejection };

export type EventWindow = { maxAgeSeconds: number; maxAheadSeconds: number };

const UINT32_MAX = 4_294_967_295;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isAbsent(value: unknown): boolean {
  return value === undefined || value === null;
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function isIntegerIn(value: unknown, minimum: number, maximum = Number.MAX_SAFE_INTEGER): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= minimum && value <= maximum;
}

function fitsBytes(value: string, bytes: number): boolean {
  return Buffer.byteLength(value, "utf8") <= bytes;
}

export function parseEnvelope(body: unknown, catalog: Catalog): EnvelopeResult {
  if (!isRecord(body)) {
    return { ok: false, reason: "not_object" };
  }

  if (body.schema !== catalog.version) {
    return { ok: false, reason: "schema" };
  }

  const serverId = body.server_id;
  if (typeof serverId !== "string" || serverId.length === 0 || !fitsBytes(serverId, catalog.limits.serverIdBytes)) {
    return { ok: false, reason: "server_id" };
  }

  if (!isIntegerIn(body.place_id, 0)) {
    return { ok: false, reason: "place_id" };
  }

  if (!isIntegerIn(body.place_version, 0, UINT32_MAX)) {
    return { ok: false, reason: "place_version" };
  }

  if (!isIntegerIn(body.batch_seq, 1)) {
    return { ok: false, reason: "batch_seq" };
  }

  if (!isFiniteNumber(body.sent_at) || body.sent_at < 0) {
    return { ok: false, reason: "sent_at" };
  }

  if (!isIntegerIn(body.dropped, 0)) {
    return { ok: false, reason: "dropped" };
  }

  if (!Array.isArray(body.events)) {
    return { ok: false, reason: "events" };
  }

  if (body.events.length > catalog.limits.batchEvents) {
    return { ok: false, reason: "too_many_events" };
  }

  return {
    ok: true,
    envelope: {
      server_id: serverId,
      place_id: body.place_id,
      place_version: body.place_version,
      batch_seq: body.batch_seq,
      sent_at: body.sent_at,
      dropped: body.dropped,
      events: body.events,
    },
  };
}

function checkProp(value: unknown, type: PropType, catalog: Catalog): EventRejection | null {
  if (type === "boolean") {
    return typeof value === "boolean" ? null : "wrong_type";
  }

  if (type === "string") {
    if (typeof value !== "string") {
      return "wrong_type";
    }

    return fitsBytes(value, catalog.limits.stringBytes) ? null : "string_too_long";
  }

  if (typeof value !== "number") {
    return "wrong_type";
  }

  if (!Number.isFinite(value)) {
    return "not_finite";
  }

  if (type === "integer" && !Number.isSafeInteger(value)) {
    return "integer_expected";
  }

  return null;
}

export function validateEvent(raw: unknown, catalog: Catalog): EventResult {
  if (!isRecord(raw)) {
    return { ok: false, reason: "not_object" };
  }

  const definition = typeof raw.name === "string" ? catalog.events.get(raw.name) : undefined;
  if (definition === undefined) {
    return { ok: false, reason: "unknown_event" };
  }

  if (!isFiniteNumber(raw.at) || raw.at < 0) {
    return { ok: false, reason: "at" };
  }

  if (!isAbsent(raw.user_id) && !isIntegerIn(raw.user_id, 0)) {
    return { ok: false, reason: "user_id" };
  }

  if (!isAbsent(raw.session_id) && (typeof raw.session_id !== "string" || !fitsBytes(raw.session_id, catalog.limits.sessionIdBytes))) {
    return { ok: false, reason: "session_id" };
  }

  if (!isFiniteNumber(raw.weight) || raw.weight < 1 || raw.weight > catalog.limits.maxWeight) {
    return { ok: false, reason: "weight" };
  }

  if (!isRecord(raw.props)) {
    return { ok: false, reason: "props" };
  }

  const props: Record<string, PropValue> = {};
  for (const [prop, type] of definition.props) {
    if (!Object.hasOwn(raw.props, prop)) {
      return { ok: false, reason: "missing_prop" };
    }

    const value = raw.props[prop];
    const problem = checkProp(value, type, catalog);
    if (problem !== null) {
      return { ok: false, reason: problem };
    }

    props[prop] = value as PropValue;
  }

  if (Object.keys(raw.props).length !== definition.props.size) {
    return { ok: false, reason: "extra_prop" };
  }

  const event: TrackedEvent = { name: raw.name as string, at: raw.at, weight: raw.weight, props };
  if (!isAbsent(raw.user_id)) {
    event.user_id = raw.user_id as number;
  }

  if (!isAbsent(raw.session_id)) {
    event.session_id = raw.session_id as string;
  }

  return { ok: true, event };
}

export function checkWindow(at: number, receivedAt: number, window: EventWindow): EventRejection | null {
  if (at < receivedAt - window.maxAgeSeconds) {
    return "stale";
  }

  if (at > receivedAt + window.maxAheadSeconds) {
    return "ahead";
  }

  return null;
}
