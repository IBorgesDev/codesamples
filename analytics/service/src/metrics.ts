import { Counter, Gauge, Histogram, Registry, collectDefaultMetrics } from "prom-client";

export function createRegistry(withDefaults: boolean): Registry {
  const registry = new Registry();
  if (withDefaults) {
    collectDefaultMetrics({ register: registry });
  }

  return registry;
}

export type IngestMetrics = ReturnType<typeof createIngestMetrics>;

export function createIngestMetrics(registry: Registry) {
  return {
    registry,
    batches: new Counter({
      name: "analytics_batches_total",
      help: "Batches received, by result",
      labelNames: ["result"],
      registers: [registry],
    }),
    accepted: new Counter({
      name: "analytics_events_accepted_total",
      help: "Valid events appended to the stream, by event name",
      labelNames: ["name"],
      registers: [registry],
    }),
    rejected: new Counter({
      name: "analytics_events_rejected_total",
      help: "Events dropped by validation, by reason",
      labelNames: ["reason"],
      registers: [registry],
    }),
    duplicates: new Counter({
      name: "analytics_duplicate_batches_total",
      help: "Retried batches answered without appending anything",
      registers: [registry],
    }),
    clientDropped: new Counter({
      name: "analytics_client_dropped_events_total",
      help: "Events the game servers reported dropping before sending",
      registers: [registry],
    }),
    ingestSeconds: new Histogram({
      name: "analytics_ingest_seconds",
      help: "Batch ingest latency, by status",
      labelNames: ["status"],
      buckets: [0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1],
      registers: [registry],
    }),
    backlog: new Gauge({
      name: "analytics_backlog_entries",
      help: "Stream entries not yet acknowledged by the clickhouse group, across shards",
      registers: [registry],
    }),
  };
}

export type WorkerMetrics = ReturnType<typeof createWorkerMetrics>;

export function createWorkerMetrics(registry: Registry) {
  return {
    registry,
    rows: new Counter({
      name: "analytics_worker_rows_inserted_total",
      help: "Rows inserted into ClickHouse",
      registers: [registry],
    }),
    entries: new Counter({
      name: "analytics_worker_entries_acked_total",
      help: "Stream entries acknowledged after their rows were inserted",
      registers: [registry],
    }),
    insertSeconds: new Histogram({
      name: "analytics_worker_insert_seconds",
      help: "ClickHouse insert latency",
      buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
      registers: [registry],
    }),
    failures: new Counter({
      name: "analytics_worker_failures_total",
      help: "Failed worker steps, by stage",
      labelNames: ["stage"],
      registers: [registry],
    }),
    reclaimed: new Counter({
      name: "analytics_worker_reclaimed_entries_total",
      help: "Entries taken over from consumers idle past the claim threshold",
      registers: [registry],
    }),
    malformed: new Counter({
      name: "analytics_worker_malformed_entries_total",
      help: "Entries that could not be decoded and were acknowledged without rows",
      registers: [registry],
    }),
  };
}
