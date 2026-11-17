import { describe, expect, it } from "vitest";
import { clickhouseTime, decodeBatch, type StoredBatch, toRows } from "../src/batch.js";
import { createRegistry, createWorkerMetrics, type WorkerMetrics } from "../src/metrics.js";
import { dedupToken, fullJitter, ShardWorker, type ShardWorkerOptions, Stopped } from "../src/pipeline.js";
import { validateEvent } from "../src/validate.js";
import { catalog, FakeShardStream, FakeSink, fixtures, validFixtures } from "./support.js";

const OPTIONS: ShardWorkerOptions = {
  readCount: 200,
  blockMs: 1_000,
  claimIdleMs: 60_000,
  reclaimEveryMs: 15_000,
  backoffBaseMs: 250,
  backoffMaxMs: 15_000,
};

function storedBatch(seq: number, serverId = String(fixtures.envelope.server_id)): StoredBatch {
  const events = validFixtures.map((fixture) => {
    const result = validateEvent(fixture.event, catalog);
    if (!result.ok) {
      throw new Error(`fixture ${fixture.why} should be valid`);
    }

    return result.event;
  });

  return {
    server_id: serverId,
    place_id: Number(fixtures.envelope.place_id),
    place_version: Number(fixtures.envelope.place_version),
    batch_seq: seq,
    sent_at: Number(fixtures.envelope.sent_at),
    dropped: 0,
    received_at: Number(fixtures.envelope.sent_at) + 0.25,
    events,
  };
}

function setup(overrides: Partial<ShardWorkerOptions> = {}) {
  const log: string[] = [];
  const stream = new FakeShardStream(log);
  const sink = new FakeSink(log);
  const metrics: WorkerMetrics = createWorkerMetrics(createRegistry(false));
  const sleeps: number[] = [];
  const clock = { ms: 0 };
  const worker = new ShardWorker(stream, sink, metrics, {
    ...OPTIONS,
    now: () => clock.ms,
    sleep: async (ms) => {
      sleeps.push(ms);
    },
    random: () => 1,
    log: () => {},
    ...overrides,
  });

  return { log, stream, sink, metrics, sleeps, clock, worker };
}

async function counter(metrics: WorkerMetrics, name: keyof WorkerMetrics, labels: Record<string, string> = {}): Promise<number> {
  const metric = metrics[name];
  if (!("get" in metric)) {
    return 0;
  }

  const values: Array<{ value: number; labels: Record<string, string | number | undefined> }> = (await metric.get()).values;
  const match = values.find((value) => Object.entries(labels).every(([key, label]) => value.labels[key] === label));
  return match?.value ?? 0;
}

async function readyWorker(overrides: Partial<ShardWorkerOptions> = {}) {
  const context = setup(overrides);
  await context.worker.step();
  context.log.length = 0;
  return context;
}

describe("rows", () => {
  it("formats times as UTC milliseconds for DateTime64(3, 'UTC')", () => {
    expect(clickhouseTime(1763300000.5)).toBe("2025-11-16 13:33:20.500");
    expect(clickhouseTime(0)).toBe("1970-01-01 00:00:00.000");
  });

  it("flattens a batch into one row per event with the envelope columns", () => {
    const batch = storedBatch(3);
    const rows = toRows(batch);
    expect(rows).toHaveLength(validFixtures.length);
    const serverEvent = rows.find((row) => row.name === "live_reward");
    expect(serverEvent).toMatchObject({
      server_id: batch.server_id,
      place_id: batch.place_id,
      place_version: batch.place_version,
      user_id: 0,
      session_id: "",
      weight: 1,
      received_at: clickhouseTime(batch.received_at),
    });
    const trade = rows.find((row) => row.name === "trade_completed");
    expect(JSON.parse(trade?.props ?? "{}")).toEqual(validFixtures[0]?.event.props);
    expect(trade?.user_id).toBe(101);
  });

  it("refuses entries that are not stored batches", () => {
    expect(decodeBatch(null)).toBeNull();
    expect(decodeBatch("{")).toBeNull();
    expect(decodeBatch(JSON.stringify({ server_id: "s" }))).toBeNull();
    expect(decodeBatch(JSON.stringify(storedBatch(1)))).not.toBeNull();
  });
});

describe("dedup token and backoff", () => {
  it("derives the same token from the same entries and a different one otherwise", () => {
    const key = "analytics:events:{0}";
    expect(dedupToken(key, ["1-0", "2-0"])).toBe(dedupToken(key, ["1-0", "2-0"]));
    expect(dedupToken(key, ["1-0", "2-0"])).not.toBe(dedupToken(key, ["1-0", "3-0"]));
    expect(dedupToken(key, ["1-0"])).not.toBe(dedupToken("analytics:events:{1}", ["1-0"]));
  });

  it("caps full jitter at the maximum", () => {
    expect(fullJitter(0, 250, 15_000, () => 1)).toBe(250);
    expect(fullJitter(3, 250, 15_000, () => 0.5)).toBe(1_000);
    expect(fullJitter(30, 250, 15_000, () => 1)).toBe(15_000);
    expect(fullJitter(5, 250, 15_000, () => 0)).toBe(0);
  });
});

describe("shard worker", () => {
  it("inserts every entry of a read in one insert, then acknowledges them", async () => {
    const { stream, sink, log, worker, metrics } = await readyWorker();
    const first = stream.add(JSON.stringify(storedBatch(1)));
    const second = stream.add(JSON.stringify(storedBatch(2)));
    expect(await worker.step()).toBe(2);
    expect(sink.inserts).toHaveLength(1);
    expect(sink.inserts[0]?.rows).toHaveLength(validFixtures.length * 2);
    expect(sink.inserts[0]?.token).toBe(dedupToken(stream.key, [first, second]));
    expect(log).toEqual(["reclaim", "read-new", "insert", "ack"]);
    expect(stream.acked).toEqual([first, second]);
    expect(await counter(metrics, "rows")).toBe(validFixtures.length * 2);
  });

  it("retries a failed insert with the same token and acknowledges only after it lands", async () => {
    const { stream, sink, log, worker, sleeps, metrics } = await readyWorker();
    const id = stream.add(JSON.stringify(storedBatch(1)));
    sink.failuresLeft = 2;
    await worker.step();
    expect(sink.attempts).toHaveLength(3);
    expect(new Set(sink.attempts).size).toBe(1);
    expect(log).toEqual(["reclaim", "read-new", "insert-failed", "touch", "insert-failed", "touch", "insert", "ack"]);
    expect(stream.touched).toEqual([[id], [id]]);
    expect(sleeps).toEqual([250, 500]);
    expect(stream.acked).toEqual([id]);
    expect(await counter(metrics, "failures", { stage: "insert" })).toBe(2);
  });

  it("never acknowledges when stopped while the insert keeps failing", async () => {
    const controller = new AbortController();
    const { stream, sink, worker } = await readyWorker({
      sleep: async () => {
        controller.abort();
      },
    });
    const id = stream.add(JSON.stringify(storedBatch(1)));
    sink.failuresLeft = Number.POSITIVE_INFINITY;
    await expect(worker.step(controller.signal)).rejects.toBeInstanceOf(Stopped);
    expect(stream.acked).toEqual([]);
    expect(stream.pending.has(id)).toBe(true);
    expect(sink.inserts).toHaveLength(0);
  });

  it("first replays its own pending entries as one group, with the token of the interrupted insert", async () => {
    const { stream, sink, log, worker } = setup();
    const interrupted = [stream.holdPending(JSON.stringify(storedBatch(1))), stream.holdPending(JSON.stringify(storedBatch(2)))];
    stream.add(JSON.stringify(storedBatch(3)));
    await worker.step();
    expect(log).toEqual(["read-pending", "insert", "ack"]);
    expect(sink.inserts[0]?.token).toBe(dedupToken(stream.key, interrupted));
    await worker.step();
    await worker.step();
    expect(log.slice(3)).toEqual(["read-pending", "reclaim", "read-new", "insert", "ack"]);
    expect(stream.acked).toHaveLength(3);
  });

  it("takes over entries a dead consumer left idle and inserts them before reading new ones", async () => {
    const { stream, sink, log, worker, metrics } = setup();
    const orphans = [stream.orphan(JSON.stringify(storedBatch(1))), stream.orphan(JSON.stringify(storedBatch(2)))];
    await worker.step();
    await worker.step();
    expect(log).toEqual(["read-pending", "reclaim", "insert", "ack"]);
    expect(sink.inserts[0]?.token).toBe(dedupToken(stream.key, orphans));
    expect(stream.acked).toEqual(orphans);
    expect(await counter(metrics, "reclaimed")).toBe(2);
  });

  it("checks for idle entries again only after the reclaim interval", async () => {
    const { log, worker, clock } = await readyWorker();
    await worker.step();
    await worker.step();
    clock.ms += OPTIONS.reclaimEveryMs;
    await worker.step();
    expect(log.filter((entry) => entry === "reclaim")).toHaveLength(2);
  });

  it("acknowledges malformed or trimmed entries without inserting them", async () => {
    const { stream, sink, worker, metrics } = await readyWorker();
    const broken = stream.add("{not json");
    const trimmed = stream.add(null);
    await worker.step();
    expect(sink.attempts).toHaveLength(0);
    expect(stream.acked).toEqual([broken, trimmed]);
    expect(await counter(metrics, "malformed")).toBe(2);
  });

  it("keeps running after a failed read, backing off first", async () => {
    const controller = new AbortController();
    const { stream, sink, sleeps, worker } = setup({
      sleep: async (ms) => {
        sleeps.push(ms);
      },
    });
    stream.failNextRead = true;
    stream.add(JSON.stringify(storedBatch(1)));
    let steps = 0;
    const original = worker.step.bind(worker);
    worker.step = async (signal) => {
      steps += 1;
      if (steps > 4) {
        controller.abort();
      }

      return original(signal);
    };
    await worker.run(controller.signal);
    expect(sleeps.length).toBeGreaterThanOrEqual(1);
    expect(sink.inserts).toHaveLength(1);
  });
});
