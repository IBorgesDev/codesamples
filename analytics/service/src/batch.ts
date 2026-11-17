import { isRecord } from "./record.js";
import type { Envelope, TrackedEvent } from "./validate.js";

export type QueuedBatch = {
  server_id: string;
  place_id: number;
  place_version: number;
  received_at: number;
  events: TrackedEvent[];
};

export type EventRow = {
  at: string;
  received_at: string;
  name: string;
  server_id: string;
  place_id: number;
  place_version: number;
  user_id: number;
  session_id: string;
  weight: number;
  props: string;
};

const ANONYMOUS_USER = 0;
const NO_SESSION = "";

function clickhouseTime(seconds: number): string {
  return new Date(Math.round(seconds * 1000)).toISOString().replace("T", " ").replace("Z", "");
}

export function encodeBatch(envelope: Envelope, receivedAt: number, events: TrackedEvent[]): string {
  const batch: QueuedBatch = {
    server_id: envelope.server_id,
    place_id: envelope.place_id,
    place_version: envelope.place_version,
    received_at: receivedAt,
    events,
  };

  return JSON.stringify(batch);
}

function isQueuedEvent(value: unknown): value is TrackedEvent {
  return (
    isRecord(value) &&
    typeof value.name === "string" &&
    typeof value.at === "number" &&
    typeof value.weight === "number" &&
    (value.user_id === undefined || typeof value.user_id === "number") &&
    (value.session_id === undefined || typeof value.session_id === "string") &&
    isRecord(value.props)
  );
}

function isQueuedBatch(value: unknown): value is QueuedBatch {
  return (
    isRecord(value) &&
    typeof value.server_id === "string" &&
    typeof value.place_id === "number" &&
    typeof value.place_version === "number" &&
    typeof value.received_at === "number" &&
    Array.isArray(value.events) &&
    value.events.every(isQueuedEvent)
  );
}

export function decodeBatch(text: string | null): QueuedBatch | null {
  if (text === null) {
    return null;
  }

  try {
    const value: unknown = JSON.parse(text);
    return isQueuedBatch(value) ? value : null;
  } catch {
    return null;
  }
}

export function toRows(batch: QueuedBatch): EventRow[] {
  const receivedAt = clickhouseTime(batch.received_at);
  return batch.events.map((event) => ({
    at: clickhouseTime(event.at),
    received_at: receivedAt,
    name: event.name,
    server_id: batch.server_id,
    place_id: batch.place_id,
    place_version: batch.place_version,
    user_id: event.user_id ?? ANONYMOUS_USER,
    session_id: event.session_id ?? NO_SESSION,
    weight: event.weight,
    props: JSON.stringify(event.props),
  }));
}
