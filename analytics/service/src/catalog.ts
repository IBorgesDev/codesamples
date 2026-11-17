import { readFileSync } from "node:fs";

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

const PROP_TYPES: ReadonlySet<string> = new Set(["string", "number", "integer", "boolean"]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function positiveInteger(source: Record<string, unknown>, field: string): number {
  const value = source[field];
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1) {
    throw new Error(`catalog: limits.${field} must be a positive integer`);
  }

  return value;
}

export function parseCatalog(raw: unknown): Catalog {
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
      if (typeof type !== "string" || !PROP_TYPES.has(type)) {
        throw new Error(`catalog: ${name}.${prop} has unknown type ${String(type)}`);
      }

      props.set(prop, type as PropType);
    }

    events.set(name, { props });
  }

  return { version: raw.version, limits, events };
}

export function loadCatalog(path: string): Catalog {
  return parseCatalog(JSON.parse(readFileSync(path, "utf8")));
}
