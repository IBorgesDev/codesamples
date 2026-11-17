import { gzipSync } from "node:zlib";
import type { FastifyInstance } from "fastify";
import { afterEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { StoredBatch } from "../src/batch.js";
import type { IngestConfig } from "../src/config.js";
import { createIngestMetrics, createRegistry, type IngestMetrics } from "../src/metrics.js";
import { ClickHouseStats, OVERVIEW_SQL, PLAYERS_SQL, TRADE_OUTCOMES_SQL, TRADE_TOTALS_SQL } from "../src/stats.js";
import { catalog, config, FakeBatchStore, FakeQueryRunner, fixtureBatch, fixtures, invalidFixtures, validFixtures } from "./support.js";

const SERVER = { authorization: "Bearer server-token" };
const READ = { authorization: "Bearer read-token" };
const JSON_TYPE = { "content-type": "application/json" };
const SENT_AT_MS = Number(fixtures.envelope.sent_at) * 1000;

type Harness = {
  app: FastifyInstance;
  store: FakeBatchStore;
  runner: FakeQueryRunner;
  metrics: IngestMetrics;
  clock: { ms: number };
};

const open: Harness[] = [];

function harness(overrides: Partial<IngestConfig> = {}, answer?: (sql: string) => unknown[]): Harness {
  const store = new FakeBatchStore();
  const runner = new FakeQueryRunner(answer);
  const metrics = createIngestMetrics(createRegistry(false));
  const clock = { ms: SENT_AT_MS };
  const app = buildApp({
    config: { ...config, ...overrides },
    catalog,
    store,
    stats: new ClickHouseStats(runner),
    metrics,
    now: () => clock.ms,
    log: () => {},
  });
  const built = { app, store, runner, metrics, clock };
  open.push(built);
  return built;
}

afterEach(async () => {
  for (const { app } of open.splice(0)) {
    await app.close();
  }
});

function post(h: Harness, body: unknown, options: { gzip?: boolean; headers?: Record<string, string> } = {}) {
  const raw = Buffer.from(typeof body === "string" ? body : JSON.stringify(body));
  const gzip = options.gzip ?? true;
  return h.app.inject({
    method: "POST",
    url: "/v1/batch",
    headers: { ...SERVER, ...JSON_TYPE, ...(gzip ? { "content-encoding": "gzip" } : {}), ...options.headers },
    payload: gzip ? gzipSync(raw) : raw,
  });
}

async function metricValue(h: Harness, name: string, labels: Record<string, string> = {}): Promise<number> {
  const metric = await h.metrics.registry.getSingleMetric(name)?.get();
  const values: Array<{ value: number; labels: Record<string, string | number | undefined> }> = metric?.values ?? [];
  const match = values.find((value) => Object.entries(labels).every(([key, label]) => value.labels[key] === label));
  return match?.value ?? 0;
}

describe("POST /v1/batch", () => {
  it.each([true, false])("keeps valid events and counts invalid ones (gzip = %s)", async (gzip) => {
    const h = harness();
    const response = await post(h, fixtureBatch(), { gzip });
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ accepted: validFixtures.length, rejected: invalidFixtures.length, duplicate: false });
    expect(h.store.appended).toHaveLength(1);
  });

  it("stores the envelope with only the valid events, normalized, plus received_at", async () => {
    const h = harness();
    h.clock.ms = SENT_AT_MS + 250;
    await post(h, fixtureBatch({ debug: true }));
    const stored = JSON.parse(h.store.appended[0]?.payload ?? "{}") as StoredBatch & Record<string, unknown>;
    expect(stored.server_id).toBe(fixtures.envelope.server_id);
    expect(stored.batch_seq).toBe(fixtures.envelope.batch_seq);
    expect(stored.received_at).toBe(h.clock.ms / 1000);
    expect(stored.debug).toBeUndefined();
    expect(stored.events.map((event) => event.name)).toEqual(validFixtures.map((fixture) => fixture.event.name));
  });

  it("answers a retried batch as a duplicate and appends nothing", async () => {
    const h = harness();
    const first = await post(h, fixtureBatch());
    const again = await post(h, fixtureBatch());
    expect(first.json().duplicate).toBe(false);
    expect(again.statusCode).toBe(200);
    expect(again.json()).toEqual({ accepted: validFixtures.length, rejected: invalidFixtures.length, duplicate: true });
    expect(h.store.appended).toHaveLength(1);
    expect(await metricValue(h, "analytics_duplicate_batches_total")).toBe(1);
    expect(await metricValue(h, "analytics_events_accepted_total", { name: "trade_completed" })).toBe(1);
  });

  it("treats the same seq from another server as a new batch", async () => {
    const h = harness();
    await post(h, fixtureBatch());
    const other = await post(h, fixtureBatch({ server_id: "another-server" }));
    expect(other.json().duplicate).toBe(false);
    expect(h.store.appended).toHaveLength(2);
  });

  it("marks a batch with no valid events as seen without appending it", async () => {
    const h = harness();
    const response = await post(h, fixtureBatch({ events: invalidFixtures.map((fixture) => fixture.event) }));
    expect(response.json()).toEqual({ accepted: 0, rejected: invalidFixtures.length, duplicate: false });
    expect(h.store.appended).toHaveLength(0);
    expect(h.store.seen.size).toBe(1);
  });

  it("counts rejected events by reason", async () => {
    const h = harness();
    await post(h, fixtureBatch());
    expect(await metricValue(h, "analytics_events_rejected_total", { reason: "unknown_event" })).toBe(1);
    expect(await metricValue(h, "analytics_events_rejected_total", { reason: "integer_expected" })).toBe(1);
    expect(await metricValue(h, "analytics_batches_total", { result: "stored" })).toBe(1);
  });

  it("rejects events outside the receive window", async () => {
    const h = harness();
    h.clock.ms = SENT_AT_MS + (config.eventMaxAgeSeconds + 60) * 1000;
    const response = await post(h, fixtureBatch());
    expect(response.json()).toEqual({ accepted: 0, rejected: fixtures.events.length, duplicate: false });
    expect(await metricValue(h, "analytics_events_rejected_total", { reason: "stale" })).toBe(validFixtures.length);
  });

  it("answers 400 with a short reason for an invalid envelope", async () => {
    const h = harness();
    const response = await post(h, fixtureBatch({ batch_seq: 0 }));
    expect(response.statusCode).toBe(400);
    expect(response.json()).toEqual({ error: "batch_seq" });
    expect(h.store.seen.size).toBe(0);
  });

  it("requires the server token", async () => {
    const h = harness();
    const missing = await post(h, fixtureBatch(), { headers: { authorization: "" } });
    const reader = await post(h, fixtureBatch(), { headers: READ });
    expect(missing.statusCode).toBe(401);
    expect(reader.statusCode).toBe(401);
    expect(h.store.seen.size).toBe(0);
  });

  it("answers 413 when the decompressed body is over the limit, even if the gzip is tiny", async () => {
    const h = harness();
    const body = JSON.stringify(fixtureBatch({ padding: "x".repeat(catalog.limits.batchBytes) }));
    const compressed = gzipSync(body);
    expect(compressed.length).toBeLessThan(catalog.limits.batchBytes / 50);
    const response = await post(h, body);
    expect(response.statusCode).toBe(413);
    expect(response.json()).toEqual({ error: "too_large" });
  });

  it("answers 413 for a plain body over the limit", async () => {
    const h = harness();
    const response = await post(h, fixtureBatch({ padding: "x".repeat(catalog.limits.batchBytes) }), { gzip: false });
    expect(response.statusCode).toBe(413);
  });

  it("accepts a body just under the limit once decompressed", async () => {
    const h = harness();
    const base = JSON.stringify(fixtureBatch({ padding: "" }));
    const padding = "x".repeat(catalog.limits.batchBytes - Buffer.byteLength(base));
    const response = await post(h, fixtureBatch({ padding }));
    expect(response.statusCode).toBe(200);
  });

  it("answers 400 for a corrupt gzip body and 415 for an unknown encoding", async () => {
    const h = harness();
    const corrupt = await h.app.inject({
      method: "POST",
      url: "/v1/batch",
      headers: { ...SERVER, ...JSON_TYPE, "content-encoding": "gzip" },
      payload: gzipSync(JSON.stringify(fixtureBatch())).subarray(0, 20),
    });
    const brotli = await post(h, fixtureBatch(), { gzip: false, headers: { "content-encoding": "br" } });
    expect(corrupt.statusCode).toBe(400);
    expect(corrupt.json()).toEqual({ error: "invalid_gzip" });
    expect(brotli.statusCode).toBe(415);
    expect(brotli.json()).toEqual({ error: "unsupported_encoding" });
  });

  it("answers 400 for a body that is not JSON", async () => {
    const h = harness();
    const response = await post(h, "{not json", { gzip: true });
    expect(response.statusCode).toBe(400);
    expect(response.json()).toEqual({ error: "invalid_json" });
  });

  it("answers 503 with Retry-After when the backlog is over the limit, and appends nothing", async () => {
    const h = harness();
    h.store.backlogValue = config.maxBacklog + 1;
    const response = await post(h, fixtureBatch());
    expect(response.statusCode).toBe(503);
    expect(response.headers["retry-after"]).toBe(String(config.retryAfterSeconds));
    expect(response.json()).toEqual({ error: "backpressure" });
    expect(h.store.seen.size).toBe(0);
    expect(await metricValue(h, "analytics_backlog_entries")).toBe(config.maxBacklog + 1);
  });

  it("reads the backlog at most once per second", async () => {
    const h = harness();
    for (let seq = 1; seq <= 5; seq++) {
      await post(h, fixtureBatch({ batch_seq: seq }));
    }

    expect(h.store.backlogReads).toBe(1);
    h.store.backlogValue = config.maxBacklog + 1;
    h.clock.ms += 999;
    expect((await post(h, fixtureBatch({ batch_seq: 6 }))).statusCode).toBe(200);
    h.clock.ms += 1;
    expect((await post(h, fixtureBatch({ batch_seq: 7 }))).statusCode).toBe(503);
    expect(h.store.backlogReads).toBe(2);
  });

  it("answers 503 with Retry-After when the store is down, so the game keeps the batch", async () => {
    const h = harness();
    h.store.failing = true;
    const response = await post(h, fixtureBatch());
    expect(response.statusCode).toBe(503);
    expect(response.headers["retry-after"]).toBe(String(config.retryAfterSeconds));
    expect(response.json()).toEqual({ error: "unavailable" });
  });
});

describe("stats API", () => {
  it("requires the read token", async () => {
    const h = harness();
    const none = await h.app.inject({ method: "GET", url: "/v1/stats/overview" });
    const server = await h.app.inject({ method: "GET", url: "/v1/stats/trades", headers: SERVER });
    expect(none.statusCode).toBe(401);
    expect(server.statusCode).toBe(401);
    expect(h.runner.calls).toHaveLength(0);
  });

  it.each([
    ["60", 60],
    ["0", 1],
    ["-5", 1],
    ["999999", config.statsMaxMinutes],
    ["abc", 60],
    ["1;DROP TABLE analytics.events", 1],
  ])("clamps minutes=%s to %d and sends it as a query parameter", async (raw, expected) => {
    const h = harness();
    const response = await h.app.inject({ method: "GET", url: `/v1/stats/overview?minutes=${encodeURIComponent(raw)}`, headers: READ });
    expect(response.statusCode).toBe(200);
    expect(response.json().minutes).toBe(expected);
    expect(h.runner.calls).toHaveLength(2);
    expect(h.runner.calls).toEqual(
      expect.arrayContaining([
        { sql: OVERVIEW_SQL, params: { minutes: expected } },
        { sql: PLAYERS_SQL, params: { minutes: expected } },
      ]),
    );
  });

  it("returns per minute and per event weighted counts, unique users, and unique players per minute across events", async () => {
    const h = harness({}, (sql) =>
      sql === PLAYERS_SQL
        ? [
            { minute_start: 1763300040, users: 14 },
            { minute_start: 1763300100, users: 11 },
          ]
        : [
            { minute_start: 1763300040, name: "session_start", weighted: 5, events: 5, users: 5 },
            { minute_start: 1763300040, name: "trade_completed", weighted: 12, events: 12, users: 9 },
          ],
    );
    const response = await h.app.inject({ method: "GET", url: "/v1/stats/overview", headers: READ });
    expect(response.json()).toEqual({
      minutes: 60,
      rows: [
        { minute: 1763300040, name: "session_start", weighted: 5, events: 5, users: 5 },
        { minute: 1763300040, name: "trade_completed", weighted: 12, events: 12, users: 9 },
      ],
      players: [
        { minute: 1763300040, users: 14 },
        { minute: 1763300100, users: 11 },
      ],
    });
  });

  it("returns trade outcomes, cross-server share and latency quantiles", async () => {
    const h = harness({}, (sql) =>
      sql === TRADE_TOTALS_SQL
        ? [{ trades: 10, cross_server: 4, latency: [2.9, 4.6] }]
        : [
            { outcome: "committed", trades: 8, cross_server: 3, latency: [2.8, 4.1] },
            { outcome: "aborted", trades: 2, cross_server: 1, latency: [null, null] },
          ],
    );
    const response = await h.app.inject({ method: "GET", url: "/v1/stats/trades?minutes=30", headers: READ });
    expect(response.json()).toEqual({
      minutes: 30,
      trades: 10,
      cross_server_share: 0.4,
      seconds: { p50: 2.9, p95: 4.6 },
      outcomes: [
        { outcome: "committed", trades: 8, cross_server: 3, p50: 2.8, p95: 4.1 },
        { outcome: "aborted", trades: 2, cross_server: 1, p50: null, p95: null },
      ],
    });
    expect(h.runner.calls.map((call) => call.sql).sort()).toEqual([TRADE_OUTCOMES_SQL, TRADE_TOTALS_SQL].sort());
    expect(h.runner.calls.every((call) => call.params.minutes === 30)).toBe(true);
  });

  it("never interpolates request input into SQL", () => {
    for (const sql of [OVERVIEW_SQL, PLAYERS_SQL, TRADE_TOTALS_SQL, TRADE_OUTCOMES_SQL]) {
      expect(sql).toContain("{minutes:UInt32}");
    }
  });

  it("answers 503 when ClickHouse is unavailable", async () => {
    const h = harness();
    h.runner.failing = true;
    const response = await h.app.inject({ method: "GET", url: "/v1/stats/overview", headers: READ });
    expect(response.statusCode).toBe(503);
    expect(response.json()).toEqual({ error: "stats_unavailable" });
  });
});

describe("operations", () => {
  it("reports health from the store and exposes metrics", async () => {
    const h = harness();
    expect((await h.app.inject({ method: "GET", url: "/healthz" })).statusCode).toBe(200);
    h.store.failing = true;
    expect((await h.app.inject({ method: "GET", url: "/healthz" })).statusCode).toBe(503);
    const metrics = await h.app.inject({ method: "GET", url: "/metrics" });
    expect(metrics.body).toContain("analytics_batches_total");
    expect(metrics.body).toContain("analytics_ingest_seconds");
  });
});
