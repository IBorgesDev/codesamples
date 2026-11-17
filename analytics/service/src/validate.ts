import type { Catalog, PropType } from "./catalog.js";
import { isRecord } from "./record.js";

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
  | "string_not_text"
  | "stale"
  | "ahead";

export type EnvelopeResult = { ok: true; envelope: Envelope } | { ok: false; reason: EnvelopeError };

export type EventResult = { ok: true; event: TrackedEvent } | { ok: false; reason: EventRejection };

export type EventWindow = { maxAgeSeconds: number; maxAheadSeconds: number };

const UINT32_MAX = 4_294_967_295;
const ID = /^[A-Za-z0-9_-]+$/;
const CONTROL_CHARACTER = /[\u0000-\u001f\u007f]/;

function isAbsent(value: unknown): value is null | undefined {
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

function isId(value: unknown, bytes: number): value is string {
  return typeof value === "string" && ID.test(value) && value.length <= bytes;
}

function isPlainText(value: string): boolean {
  return value.isWellFormed() && !CONTROL_CHARACTER.test(value);
}

export function parseEnvelope(body: unknown, catalog: Catalog): EnvelopeResult {
  if (!isRecord(body)) {
    return { ok: false, reason: "not_object" };
  }

  if (body.schema !== catalog.version) {
    return { ok: false, reason: "schema" };
  }

  const { server_id, place_id, place_version, batch_seq, sent_at, dropped, events } = body;
  if (!isId(server_id, catalog.limits.serverIdBytes)) {
    return { ok: false, reason: "server_id" };
  }

  if (!isIntegerIn(place_id, 0)) {
    return { ok: false, reason: "place_id" };
  }

  if (!isIntegerIn(place_version, 0, UINT32_MAX)) {
    return { ok: false, reason: "place_version" };
  }

  if (!isIntegerIn(batch_seq, 1)) {
    return { ok: false, reason: "batch_seq" };
  }

  if (!isFiniteNumber(sent_at) || sent_at < 0) {
    return { ok: false, reason: "sent_at" };
  }

  if (!isIntegerIn(dropped, 0, UINT32_MAX)) {
    return { ok: false, reason: "dropped" };
  }

  if (!Array.isArray(events)) {
    return { ok: false, reason: "events" };
  }

  if (events.length > catalog.limits.batchEvents) {
    return { ok: false, reason: "too_many_events" };
  }

  return { ok: true, envelope: { server_id, place_id, place_version, batch_seq, dropped, events } };
}

function checkProp(value: unknown, type: PropType, catalog: Catalog): EventRejection | null {
  if (type === "boolean") {
    return typeof value === "boolean" ? null : "wrong_type";
  }

  if (type === "string") {
    if (typeof value !== "string") {
      return "wrong_type";
    }

    if (!fitsBytes(value, catalog.limits.stringBytes)) {
      return "string_too_long";
    }

    return isPlainText(value) ? null : "string_not_text";
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

function propsOf(raw: unknown): Record<string, unknown> | null {
  if (Array.isArray(raw) && raw.length === 0) {
    return {};
  }

  return isRecord(raw) ? raw : null;
}

export function validateEvent(raw: unknown, catalog: Catalog): EventResult {
  if (!isRecord(raw)) {
    return { ok: false, reason: "not_object" };
  }

  const { name, at, user_id, session_id, weight } = raw;
  const definition = typeof name === "string" ? catalog.events.get(name) : undefined;
  if (typeof name !== "string" || definition === undefined) {
    return { ok: false, reason: "unknown_event" };
  }

  if (!isFiniteNumber(at) || at < 0) {
    return { ok: false, reason: "at" };
  }

  if (!isAbsent(user_id) && !isIntegerIn(user_id, 0)) {
    return { ok: false, reason: "user_id" };
  }

  if (!isAbsent(session_id) && !isId(session_id, catalog.limits.sessionIdBytes)) {
    return { ok: false, reason: "session_id" };
  }

  if (!isFiniteNumber(weight) || weight < 1 || weight > catalog.limits.maxWeight) {
    return { ok: false, reason: "weight" };
  }

  const given = propsOf(raw.props);
  if (given === null) {
    return { ok: false, reason: "props" };
  }

  const props: Record<string, PropValue> = {};
  for (const [prop, type] of definition.props) {
    if (!Object.hasOwn(given, prop)) {
      return { ok: false, reason: "missing_prop" };
    }

    const value = given[prop];
    const problem = checkProp(value, type, catalog);
    if (problem !== null) {
      return { ok: false, reason: problem };
    }

    if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
      props[prop] = value;
    }
  }

  if (Object.keys(given).length !== definition.props.size) {
    return { ok: false, reason: "extra_prop" };
  }

  const event: TrackedEvent = { name, at, weight, props };
  if (!isAbsent(user_id)) {
    event.user_id = user_id;
  }

  if (!isAbsent(session_id)) {
    event.session_id = session_id;
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
