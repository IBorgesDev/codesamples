import type { Envelope, TrackedEvent } from "./validate.js";

export type StoredBatch = Omit<Envelope, "events"> & {
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

export function clickhouseTime(seconds: number): string {
  return new Date(Math.round(seconds * 1000)).toISOString().replace("T", " ").replace("Z", "");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isEvent(value: unknown): value is TrackedEvent {
  return (
    isRecord(value) &&
    typeof value.name === "string" &&
    typeof value.at === "number" &&
    typeof value.weight === "number" &&
    isRecord(value.props)
  );
}

export function decodeBatch(text: string | null): StoredBatch | null {
  if (text === null) {
    return null;
  }

  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    return null;
  }

  if (
    !isRecord(value) ||
    typeof value.server_id !== "string" ||
    typeof value.place_id !== "number" ||
    typeof value.place_version !== "number" ||
    typeof value.received_at !== "number" ||
    !Array.isArray(value.events) ||
    !value.events.every(isEvent)
  ) {
    return null;
  }

  return value as StoredBatch;
}

export function toRows(batch: StoredBatch): EventRow[] {
  const receivedAt = clickhouseTime(batch.received_at);
  return batch.events.map((event) => ({
    at: clickhouseTime(event.at),
    received_at: receivedAt,
    name: event.name,
    server_id: batch.server_id,
    place_id: batch.place_id,
    place_version: batch.place_version,
    user_id: event.user_id ?? 0,
    session_id: event.session_id ?? "",
    weight: event.weight,
    props: JSON.stringify(event.props),
  }));
}
