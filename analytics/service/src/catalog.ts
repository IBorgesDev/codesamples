import { readFileSync } from "node:fs";
import { isRecord } from "./record.js";

export type PropType = "string" | "number" | "integer" | "boolean";

export type Limits = {
  stringBytes: number;
  serverIdBytes: number;
  sessionIdBytes: number;
  batchEvents: number;
  batchBytes: number;
  maxWeight: number;
};

export type EventDefinition = {
  props: Map<string, PropType>;
};

export type Catalog = {
  version: number;
  limits: Limits;
  events: Map<string, EventDefinition>;
};

const PROP_TYPES: ReadonlySet<unknown> = new Set<PropType>(["string", "number", "integer", "boolean"]);

function isPropType(value: unknown): value is PropType {
  return PROP_TYPES.has(value);
}

function positiveInteger(source: Record<string, unknown>, field: string): number {
  const value = source[field];
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1) {
    throw new Error(`catalog: limits.${field} must be a positive integer`);
  }

  return value;
}

function parseCatalog(raw: unknown): Catalog {
  if (!isRecord(raw) || !isRecord(raw.limits) || !isRecord(raw.events)) {
    throw new Error("catalog: expected { version, limits, events }");
  }

  if (typeof raw.version !== "number" || !Number.isSafeInteger(raw.version)) {
    throw new Error("catalog: version must be an integer");
  }

  const limits: Limits = {
    stringBytes: positiveInteger(raw.limits, "string_bytes"),
    serverIdBytes: positiveInteger(raw.limits, "server_id_bytes"),
    sessionIdBytes: positiveInteger(raw.limits, "session_id_bytes"),
    batchEvents: positiveInteger(raw.limits, "batch_events"),
    batchBytes: positiveInteger(raw.limits, "batch_bytes"),
    maxWeight: positiveInteger(raw.limits, "max_weight"),
  };

  const events = new Map<string, EventDefinition>();
  for (const [name, definition] of Object.entries(raw.events)) {
    if (!isRecord(definition) || !isRecord(definition.props)) {
      throw new Error(`catalog: event ${name} needs a props object`);
    }

    const props = new Map<string, PropType>();
    for (const [prop, type] of Object.entries(definition.props)) {
      if (!isPropType(type)) {
        throw new Error(`catalog: ${name}.${prop} has unknown type ${String(type)}`);
      }

      props.set(prop, type);
    }

    events.set(name, { props });
  }

  return { version: raw.version, limits, events };
}

export function loadCatalog(path: string): Catalog {
  return parseCatalog(JSON.parse(readFileSync(path, "utf8")));
}
