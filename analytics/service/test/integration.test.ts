import { existsSync, readFileSync } from "node:fs";
import { gzipSync } from "node:zlib";
import { Redis } from "ioredis";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import { type StoredBatch, toRows } from "../src/batch.js";
import { ClickHouse } from "../src/clickhouse.js";
import { CONSUMER_GROUP, shardOf, streamKey } from "../src/keys.js";
import { createIngestMetrics, createRegistry, createWorkerMetrics } from "../src/metrics.js";
import { dedupToken, type RowSink, ShardWorker, type ShardWorkerOptions } from "../src/pipeline.js";
import { ClickHouseStats } from "../src/stats.js";
import { RedisBatchStore } from "../src/store.js";
import { RedisShardStream } from "../src/stream.js";
import { validateEvent } from "../src/validate.js";
import { catalog, config, FakeQueryRunner, FakeSink, fixtures, validFixtures } from "./support.js";

const ENV_FILE = new URL("../../infra/.env", import.meta.url);
const INIT_SQL = new URL("../../clickhouse/init.sql", import.meta.url);
const SHARDS = 4;
const SERVER = { authorization: "Bearer server-token", "content-type": "application/json", "content-encoding": "gzip" };
const READ = { authorization: "Bearer read-token" };

function envValue(name: string): string {
  const fromProcess = process.env[name];
  if (fromProcess) {
    return fromProcess;
  }

  if (!existsSync(ENV_FILE)) {
    return "";
  }

  return readFileSync(ENV_FILE, "utf8").match(new RegExp(`^${name}=(.*)$`, "m"))?.[1]?.trim() ?? "";
}

async function reachableRedis(): Promise<Redis | null> {
  const url = process.env.REDIS_TEST_URL ?? `redis://:${envValue("REDIS_PASSWORD")}@localhost:6380/14`;
  const redis = new Redis(url, { lazyConnect: true, connectTimeout: 1_000, maxRetriesPerRequest: 1, retryStrategy: () => null });
  redis.on("error", () => {});
  try {
    await redis.connect();
    await redis.ping();
    return redis;
  } catch {
    redis.disconnect();
    return null;
  }
}

const redis = await reachableRedis();
const clickhouse = new ClickHouse({
  url: process.env.CLICKHOUSE_TEST_URL ?? "http://localhost:8123",
  user: envValue("CLICKHOUSE_USER") || "default",
  password: envValue("CLICKHOUSE_PASSWORD"),
  timeoutMs: 5_000,
});
const clickhouseUp = await clickhouse.ping();

const WORKER_OPTIONS: ShardWorkerOptions = {
  readCount: 200,
  blockMs: 10,
  claimIdleMs: 60_000,
  reclaimEveryMs: 0,
  backoffBaseMs: 1,
  backoffMaxMs: 5,
  log: () => {},
};

function serverOnShard(shard: number, prefix: string): string {
  for (let n = 0; ; n++) {
    const candidate = `${prefix}-${n}`;
    if (shardOf(candidate, SHARDS) === shard) {
      return candidate;
    }
  }
}

function batchAt(serverId: string, seq: number, nowSeconds: number) {
  return {
    ...fixtures.envelope,
    server_id: serverId,
    batch_seq: seq,
    sent_at: nowSeconds,
    events: validFixtures.map((fixture, index) => ({ ...fixture.event, at: nowSeconds - index * 0.1 })),
  };
}

function storedAt(serverId: string, seq: number, nowSeconds: number): StoredBatch {
  const envelope = batchAt(serverId, seq, nowSeconds);
  return {
    server_id: serverId,
    place_id: Number(fixtures.envelope.place_id),
    place_version: Number(fixtures.envelope.place_version),
    batch_seq: seq,
    sent_at: nowSeconds,
    dropped: 0,
    received_at: nowSeconds,
    events: envelope.events.map((event) => {
      const result = validateEvent(event, catalog);
      if (!result.ok) {
        throw new Error("fixture event should be valid");
      }

      return result.event;
    }),
  };
}

function storeOn(connection: Redis) {
  return new RedisBatchStore(connection, { shards: SHARDS, dedupeTtlSeconds: 60 });
}

const connections: Redis[] = [];

function connection(): Redis {
  const duplicate = (redis as Redis).duplicate();
  connections.push(duplicate);
  return duplicate;
}

afterAll(() => {
  for (const extra of connections) {
    extra.disconnect();
  }

  redis?.disconnect();
});

describe.skipIf(redis === null)("Redis stream store (real Redis)", () => {
  const live = redis as Redis;

  beforeEach(async () => {
    await live.flushdb();
  });

  it("appends a batch once per (server_id, batch_seq) and expires the dedupe key", async () => {
    const store = storeOn(live);
    await store.ensureGroups();
    expect(await store.append("server-a", 1, '{"events":[]}')).toBe("appended");
    expect(await store.append("server-a", 1, '{"events":[]}')).toBe("duplicate");
    expect(await store.append("server-a", 2, '{"events":[]}')).toBe("appended");
    const key = streamKey(shardOf("server-a", SHARDS));
    expect(await live.xlen(key)).toBe(2);
    const ttl = await live.ttl(`analytics:seen:{${shardOf("server-a", SHARDS)}}:server-a:1`);
    expect(ttl).toBeGreaterThan(0);
    expect(ttl).toBeLessThanOrEqual(60);
  });

  it("marks a batch without valid events as seen without a stream entry", async () => {
    const store = storeOn(live);
    expect(await store.append("server-b", 1, "")).toBe("appended");
    expect(await store.append("server-b", 1, "")).toBe("duplicate");
    expect(await live.exists(streamKey(shardOf("server-b", SHARDS)))).toBe(0);
  });

  it("counts undelivered and pending entries as backlog until they are acknowledged", async () => {
    const store = storeOn(live);
    await store.ensureGroups();
    const server = serverOnShard(0, "backlog");
    for (let seq = 1; seq <= 3; seq++) {
      await store.append(server, seq, JSON.stringify({ seq }));
    }

    expect(await store.backlog()).toBe(3);
    const stream = new RedisShardStream(connection(), streamKey(0), "reader");
    const read = await stream.readNew(2, 10);
    expect(await store.backlog()).toBe(3);
    await stream.ack(read.map((entry) => entry.id));
    expect(await store.backlog()).toBe(1);
  });

  it("trims only what every consumer has acknowledged, never a pending or unread entry", async () => {
    const key = streamKey(0);
    await new RedisShardStream(connection(), key, "reader").ensureGroup();
    for (let n = 0; n < 600; n++) {
      await live.xadd(key, "*", "batch", String(n));
    }

    const stream = new RedisShardStream(connection(), key, "reader");
    const read = await stream.readNew(400, 10);
    const ids = read.map((entry) => entry.id);
    await stream.ack(ids.slice(0, 350));
    const kept = await live.xrange(key, ids[350] as string, "+");
    expect(kept.length).toBe(250);
    expect(await live.xlen(key)).toBeLessThan(600);

    const dead = new RedisShardStream(connection(), key, "dead");
    const abandoned = await dead.readNew(100, 10);
    await stream.ack(ids.slice(350));
    expect((await live.xrange(key, abandoned[0]?.id as string, "+")).length).toBe(200);
    expect(((await live.xpending(key, "clickhouse")) as unknown[])[0]).toBe(100);
  });

  it("drops acknowledged entries once every group has read past them", async () => {
    const key = streamKey(0);
    await new RedisShardStream(connection(), key, "reader").ensureGroup();
    for (let n = 0; n < 1_000; n++) {
      await live.xadd(key, "*", "batch", String(n));
    }

    const stream = new RedisShardStream(connection(), key, "reader");
    const read = await stream.readNew(1_000, 10);
    await stream.ack(read.map((entry) => entry.id));
    expect(await live.xlen(key)).toBeLessThan(200);
  });

  it("serves the ingest route end to end, answering a retry as a duplicate", async () => {
    const store = storeOn(live);
    await store.ensureGroups();
    const app = buildApp({ config, catalog, store, stats: new ClickHouseStats(new FakeQueryRunner()), metrics: createIngestMetrics(createRegistry(false)) });
    const now = Date.now() / 1000;
    const body = gzipSync(JSON.stringify(batchAt("server-c", 1, now)));
    const first = await app.inject({ method: "POST", url: "/v1/batch", headers: SERVER, payload: body });
    const again = await app.inject({ method: "POST", url: "/v1/batch", headers: SERVER, payload: body });
    await app.close();
    expect(first.json()).toEqual({ accepted: validFixtures.length, rejected: 0, duplicate: false });
    expect(again.json().duplicate).toBe(true);
    expect(await live.xlen(streamKey(shardOf("server-c", SHARDS)))).toBe(1);
  });

  it("a restarted worker replays its interrupted read as the same group, so the token matches", async () => {
    const store = storeOn(live);
    await store.ensureGroups();
    const server = serverOnShard(1, "restart");
    const now = Date.now() / 1000;
    await store.append(server, 1, JSON.stringify(storedAt(server, 1, now)));
    await store.append(server, 2, JSON.stringify(storedAt(server, 2, now)));
    const interrupted = await new RedisShardStream(connection(), streamKey(1), "worker-a").readNew(200, 10);
    const sink = new FakeSink();
    const worker = new ShardWorker(new RedisShardStream(connection(), streamKey(1), "worker-a"), sink, createWorkerMetrics(createRegistry(false)), WORKER_OPTIONS);
    await worker.step();
    expect(sink.inserts[0]?.token).toBe(dedupToken(streamKey(1), interrupted.map((entry) => entry.id)));
    expect(sink.inserts[0]?.rows).toHaveLength(validFixtures.length * 2);
    const pending = (await live.call("XPENDING", streamKey(1), CONSUMER_GROUP)) as unknown[];
    expect(Number(pending[0])).toBe(0);
  });

  it("another worker takes over a dead consumer's entries once they are idle", async () => {
    const store = storeOn(live);
    await store.ensureGroups();
    const server = serverOnShard(2, "takeover");
    const now = Date.now() / 1000;
    await store.append(server, 1, JSON.stringify(storedAt(server, 1, now)));
    const abandoned = await new RedisShardStream(connection(), streamKey(2), "worker-dead").readNew(200, 10);
    await new Promise((resolve) => setTimeout(resolve, 60));
    const sink = new FakeSink();
    const worker = new ShardWorker(new RedisShardStream(connection(), streamKey(2), "worker-b"), sink, createWorkerMetrics(createRegistry(false)), {
      ...WORKER_OPTIONS,
      claimIdleMs: 50,
    });
    await worker.step();
    await worker.step();
    expect(sink.inserts[0]?.token).toBe(dedupToken(streamKey(2), abandoned.map((entry) => entry.id)));
    expect(await store.backlog()).toBe(0);
  });

  it("two consumers dying at once are reclaimed one group at a time, each with its original token", async () => {
    const store = storeOn(live);
    await store.ensureGroups();
    const server = serverOnShard(3, "twins");
    const now = Date.now() / 1000;
    await store.append(server, 1, JSON.stringify(storedAt(server, 1, now)));
    await store.append(server, 2, JSON.stringify(storedAt(server, 2, now)));
    const first = await new RedisShardStream(connection(), streamKey(3), "worker-dead-1").readNew(1, 10);
    const second = await new RedisShardStream(connection(), streamKey(3), "worker-dead-2").readNew(1, 10);
    await new Promise((resolve) => setTimeout(resolve, 60));
    const survivor = new RedisShardStream(connection(), streamKey(3), "worker-survivor");
    const tokens = new Set<string>();
    for (let round = 0; round < 2; round++) {
      const reclaimed = await survivor.reclaim(50, 200);
      tokens.add(dedupToken(streamKey(3), reclaimed.map((entry) => entry.id)));
      await survivor.ack(reclaimed.map((entry) => entry.id));
    }

    expect(tokens).toEqual(
      new Set([
        dedupToken(streamKey(3), first.map((entry) => entry.id)),
        dedupToken(streamKey(3), second.map((entry) => entry.id)),
      ]),
    );
    expect(await store.backlog()).toBe(0);
  });

  it("keeps entries pending while inserts fail and acknowledges them after one lands", async () => {
    const store = storeOn(live);
    await store.ensureGroups();
    const server = serverOnShard(3, "outage");
    await store.append(server, 1, JSON.stringify(storedAt(server, 1, Date.now() / 1000)));
    const sink = new FakeSink();
    sink.failuresLeft = 3;
    const worker = new ShardWorker(new RedisShardStream(connection(), streamKey(3), "worker-c"), sink, createWorkerMetrics(createRegistry(false)), WORKER_OPTIONS);
    await worker.step();
    await worker.step();
    expect(sink.attempts).toHaveLength(4);
    expect(sink.inserts).toHaveLength(1);
    expect(await store.backlog()).toBe(0);
  });
});

describe.skipIf(redis === null || !clickhouseUp)("Redis to ClickHouse (real services)", () => {
  const live = redis as Redis;
  const sink: RowSink = { insert: (rows, token) => clickhouse.insert("analytics.events", rows, token) };

  async function rowsFor(serverId: string): Promise<number> {
    const result = await clickhouse.query<{ rows: number }>(
      "SELECT count() AS rows FROM analytics.events WHERE server_id = {server:String} FORMAT JSON",
      { server: serverId },
    );
    return Number(result[0]?.rows ?? 0);
  }

  beforeAll(async () => {
    const statements = readFileSync(INIT_SQL, "utf8")
      .split(/;\s*(?:\r?\n|$)/)
      .map((statement) => statement.trim())
      .filter((statement) => statement.length > 0);
    for (const statement of statements) {
      await clickhouse.execute(statement);
    }
  });

  beforeEach(async () => {
    await live.flushdb();
  });

  it("drops a re-inserted group with the same token", async () => {
    const stamp = Date.now();
    const server = `it-dedup-${stamp}`;
    const rows = toRows(storedAt(server, 1, stamp / 1000));
    const token = dedupToken(streamKey(0), [`${stamp}-0`, `${stamp}-1`]);
    await clickhouse.insert("analytics.events", rows, token);
    await clickhouse.insert("analytics.events", rows, token);
    expect(await rowsFor(server)).toBe(rows.length);
  });

  it("moves a batch from ingest to ClickHouse exactly once, and the stats API reads it", async () => {
    const store = storeOn(live);
    await store.ensureGroups();
    const stats = new ClickHouseStats(clickhouse);
    const app = buildApp({ config, catalog, store, stats, metrics: createIngestMetrics(createRegistry(false)) });
    const server = `it-e2e-${Date.now()}`;
    const shard = shardOf(server, SHARDS);
    const body = gzipSync(JSON.stringify(batchAt(server, 1, Date.now() / 1000)));
    await app.inject({ method: "POST", url: "/v1/batch", headers: SERVER, payload: body });
    await app.inject({ method: "POST", url: "/v1/batch", headers: SERVER, payload: body });
    const worker = new ShardWorker(new RedisShardStream(connection(), streamKey(shard), "worker-e2e"), sink, createWorkerMetrics(createRegistry(false)), WORKER_OPTIONS);
    for (let step = 0; step < 3; step++) {
      await worker.step();
    }

    expect(await rowsFor(server)).toBe(validFixtures.length);
    expect(await store.backlog()).toBe(0);
    const overview = await app.inject({ method: "GET", url: "/v1/stats/overview?minutes=5", headers: READ });
    const trades = await app.inject({ method: "GET", url: "/v1/stats/trades?minutes=5", headers: READ });
    await app.close();
    expect(overview.statusCode).toBe(200);
    expect(overview.json().rows.some((row: { name: string }) => row.name === "trade_completed")).toBe(true);
    expect(overview.json().players.some((row: { users: number }) => row.users >= 2)).toBe(true);
    expect(trades.statusCode).toBe(200);
    expect(trades.json().trades).toBeGreaterThanOrEqual(1);
  });
});
