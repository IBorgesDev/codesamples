import { existsSync, readFileSync } from "node:fs";
import { Redis } from "ioredis";
import { afterAll, beforeEach, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.js";
import type { Config } from "../src/config.js";
import { EventStore, shardKeys, shardOf } from "../src/store.js";

function redisUrl(): string {
  if (process.env.REDIS_TEST_URL) {
    return process.env.REDIS_TEST_URL;
  }

  const envFile = new URL("../../infra/.env", import.meta.url);
  const password = existsSync(envFile)
    ? (readFileSync(envFile, "utf8").match(/^REDIS_PASSWORD=(.*)$/m)?.[1] ?? "")
    : (process.env.REDIS_PASSWORD ?? "");

  return `redis://:${password}@localhost:6379/15`;
}

const redis = new Redis(redisUrl(), { lazyConnect: true, connectTimeout: 1_000, maxRetriesPerRequest: 1, retryStrategy: () => null });
redis.on("error", () => {});
const reachable = await redis.connect().then(
  () => true,
  () => false,
);

const config: Config = {
  port: 0,
  redisUrl: "",
  serverToken: "server-token",
  adminToken: "admin-token",
  closeGraceSeconds: 60,
  maxEventsPerPublish: 16,
  maxOptionsPerEvent: 32,
  batchMs: 0,
  batchMax: 1000,
  shards: 8,
  totalsRefreshMs: 0,
  redisClusterNodes: [],
};

let clock = 1_000;
const store = new EventStore(redis, { closeGraceSeconds: config.closeGraceSeconds, shards: config.shards, refreshMs: 0 });
const app = buildApp({ store, redis, config, now: () => clock });

const SERVER = { authorization: "Bearer server-token" };
const ADMIN = { authorization: "Bearer admin-token" };

type Body = Record<string, { plus?: Record<string, number>; minus?: Record<string, number> }>;

async function create(id: string, body: object) {
  return app.inject({ method: "PUT", url: `/v1/events/${id}`, headers: ADMIN, payload: body });
}

async function publish(server: string, events: Body) {
  const response = await app.inject({ method: "POST", url: "/v1/publish", headers: SERVER, payload: { server, events } });
  expect(response.statusCode).toBe(200);
  return response.json();
}

function shuffle<T>(items: T[], seed: number): T[] {
  const out = [...items];
  let state = seed;
  for (let i = out.length - 1; i > 0; i--) {
    state = (state * 1103515245 + 12345) % 2147483648;
    const j = state % (i + 1);
    [out[i], out[j]] = [out[j] as T, out[i] as T];
  }

  return out;
}

beforeEach(async () => {
  await redis.flushdb();
  clock = 1_000;
});

afterAll(async () => {
  await app.close();
  redis.disconnect();
});

describe.skipIf(!reachable)("events service", () => {
  it("creates an event once and refuses a different spec under the same id", async () => {
    const spec = { options: ["fish"], goal: { option: "fish", target: 100 } };
    expect((await create("fishing", spec)).statusCode).toBe(201);
    expect((await create("fishing", spec)).statusCode).toBe(200);
    expect((await create("fishing", { options: ["fish", "shark"] })).statusCode).toBe(409);
  });

  it("a retried publish changes nothing", async () => {
    await create("fishing", { options: ["fish"] });
    const first = await publish("s1", { fishing: { plus: { fish: 5 } } });
    const again = await publish("s1", { fishing: { plus: { fish: 5 } } });
    expect(first.events.fishing.totals.fish).toBe(5);
    expect(again.events.fishing.totals.fish).toBe(5);
    expect(again.events.fishing.version).toBe(first.events.fishing.version);
  });

  it("an older cumulative value arriving late is ignored", async () => {
    await create("fishing", { options: ["fish"] });
    await publish("s1", { fishing: { plus: { fish: 9 } } });
    const late = await publish("s1", { fishing: { plus: { fish: 4 } } });
    expect(late.events.fishing.totals.fish).toBe(9);
  });

  it("40 servers publishing concurrently, with duplicates and out of order, sum exactly", async () => {
    await create("fishing", { options: ["fish"] });
    const requests: Array<[string, number]> = [];
    let expected = 0;
    for (let s = 0; s < 40; s++) {
      let cumulative = 0;
      for (let step = 0; step < 25; step++) {
        cumulative += 1 + ((s * 7 + step * 3) % 5);
        requests.push([`server-${s}`, cumulative], [`server-${s}`, cumulative]);
      }

      expected += cumulative;
    }

    await Promise.all(shuffle(requests, 42).map(([server, value]) => publish(server, { fishing: { plus: { fish: value } } })));
    const snapshot = (await app.inject({ method: "GET", url: "/v1/events/fishing", headers: SERVER })).json();
    expect(snapshot.totals.fish).toBe(expected);
    expect(snapshot.servers).toBe(40);
  });

  it("counts changed votes through retractions", async () => {
    await create("boss_vote", { options: ["kraken", "megalodon"] });
    await publish("s1", { boss_vote: { plus: { kraken: 3, megalodon: 1 } } });
    const after = await publish("s1", { boss_vote: { plus: { kraken: 3, megalodon: 2 }, minus: { kraken: 1 } } });
    expect(after.events.boss_vote.totals).toEqual({ kraken: 2, megalodon: 2 });
  });

  it("completes the goal exactly once and keeps counting after it", async () => {
    await create("fishing", { options: ["fish"], goal: { option: "fish", target: 10 } });
    await publish("s1", { fishing: { plus: { fish: 6 } } });
    clock = 1_010;
    const reached = await publish("s2", { fishing: { plus: { fish: 5 } } });
    clock = 1_020;
    const later = await publish("s1", { fishing: { plus: { fish: 8 } } });
    expect(reached.events.fishing.state).toBe("completed");
    expect(reached.events.fishing.completed_at).toBe(1_010);
    expect(later.events.fishing.completed_at).toBe(1_010);
    expect(later.events.fishing.totals.fish).toBe(13);
  });

  it("accepts late flushes until the grace ends, then freezes the totals", async () => {
    await create("fishing", { options: ["fish"], ends_at: 2_000 });
    clock = 2_030;
    const inGrace = await publish("s1", { fishing: { plus: { fish: 4 } } });
    clock = 2_061;
    const closed = await publish("s1", { fishing: { plus: { fish: 50 } } });
    expect(inGrace.events.fishing.totals.fish).toBe(4);
    expect(closed.events.fishing.state).toBe("closed");
    expect(closed.events.fishing.totals.fish).toBe(4);
  });

  it("ignores options the event does not have and reports unknown events", async () => {
    await create("fishing", { options: ["fish"] });
    const result = await publish("s1", { fishing: { plus: { fish: 1, gold: 99 } }, ghost: { plus: { fish: 1 } } });
    expect(result.events.fishing.totals).toEqual({ fish: 1 });
    expect(result.events.fishing.ignored).toBe(1);
    expect(result.missing).toEqual(["ghost"]);
  });

  it("reads an event the server has no contribution for, sent as an empty array the way Roblox encodes an empty table", async () => {
    await create("boss_vote", { options: ["kraken"] });
    await publish("s2", { boss_vote: { plus: { kraken: 2 } } });
    const empty = await app.inject({ method: "POST", url: "/v1/publish", headers: SERVER, payload: { server: "s1", events: { boss_vote: [] } } });
    const filled = await app.inject({ method: "POST", url: "/v1/publish", headers: SERVER, payload: { server: "s1", events: { boss_vote: [1] } } });
    expect(empty.statusCode).toBe(200);
    expect(empty.json().events.boss_vote.totals).toEqual({ kraken: 2 });
    expect(filled.statusCode).toBe(400);
  });

  it("rejects missing tokens and malformed payloads", async () => {
    await create("fishing", { options: ["fish"] });
    const unauthorized = await app.inject({ method: "POST", url: "/v1/publish", payload: { server: "s1", events: { fishing: {} } } });
    const negative = await app.inject({
      method: "POST",
      url: "/v1/publish",
      headers: SERVER,
      payload: { server: "s1", events: { fishing: { plus: { fish: -1 } } } },
    });
    const serverAsAdmin = await app.inject({ method: "PUT", url: "/v1/events/x", headers: SERVER, payload: { options: ["a"] } });
    expect(unauthorized.statusCode).toBe(401);
    expect(negative.statusCode).toBe(400);
    expect(serverAsAdmin.statusCode).toBe(401);
  });

  it("heals itself after Redis loses everything: servers resend their cumulative counts", async () => {
    const spec = { options: ["fish"] };
    await create("fishing", spec);
    await publish("s1", { fishing: { plus: { fish: 30 } } });
    await publish("s2", { fishing: { plus: { fish: 12 } } });
    await redis.flushdb();
    await create("fishing", spec);
    await publish("s1", { fishing: { plus: { fish: 31 } } });
    const healed = await publish("s2", { fishing: { plus: { fish: 12 } } });
    expect(healed.events.fishing.totals.fish).toBe(43);
  });

  it("batches concurrent requests through the coalescer and still adds up exactly", async () => {
    const { Coalescer } = await import("../src/coalescer.js");
    const coalescer = new Coalescer((batch) => store.publishBatch(batch, clock), 10, 1000);
    const batched = buildApp({ store, redis, config, coalescer, now: () => clock });
    await create("fishing", { options: ["fish"] });
    const requests = Array.from({ length: 200 }, (_, n) =>
      batched.inject({
        method: "POST",
        url: "/v1/publish",
        headers: SERVER,
        payload: { server: `s${n % 50}`, events: { fishing: { plus: { fish: 10 + Math.floor(n / 50) } } } },
      }),
    );
    const responses = await Promise.all(requests);
    expect(responses.every((response) => response.statusCode === 200)).toBe(true);
    const totals = (await batched.inject({ method: "GET", url: "/v1/events/fishing", headers: SERVER })).json();
    expect(totals.totals.fish).toBe(50 * 13);
    await batched.close();
  });

  it("spreads one event over its shards by server and still sums exactly", async () => {
    await create("fishing", { options: ["fish"] });
    for (let s = 0; s < 64; s++) {
      await publish(`server-${s}`, { fishing: { plus: { fish: s + 1 } } });
    }

    const used = await Promise.all(Array.from({ length: config.shards }, (_, shard) => redis.hlen(shardKeys("fishing", shard)[0] as string)));
    const snapshot = (await app.inject({ method: "GET", url: "/v1/events/fishing", headers: SERVER })).json();
    expect(used.filter((entries) => entries > 0).length).toBe(config.shards);
    expect(used.reduce((sum, entries) => sum + entries, 0)).toBe(64);
    expect(snapshot.totals.fish).toBe((64 * 65) / 2);
    expect(snapshot.servers).toBe(64);
  });

  it("stays exact across instances whose cached shard totals are old", async () => {
    let wall = 0;
    const slow = new EventStore(redis, { closeGraceSeconds: 60, shards: config.shards, refreshMs: 60_000, clock: () => wall });
    await create("fishing", { options: ["fish"] });
    const first = await slow.publish("s1", { fishing: { plus: { fish: 5 }, minus: {} } }, clock);
    await publish("s2", { fishing: { plus: { fish: 7 } } });
    await publish("s3", { fishing: { plus: { fish: 9 } } });
    wall = 61_000;
    const later = await slow.publish("s1", { fishing: { plus: { fish: 6 }, minus: {} } }, clock);
    expect(first.fishing?.totals.fish).toBe(5);
    expect(later.fishing?.totals.fish).toBe(22);
    expect((await slow.read("fishing", clock))?.totals.fish).toBe(22);
  });

  it("keeps the shard count an event was created with, so changing it never counts a server twice", async () => {
    const wider = new EventStore(redis, { closeGraceSeconds: 60, shards: 32, refreshMs: 0 });
    await create("fishing", { options: ["fish"] });
    for (let s = 0; s < 20; s++) {
      await publish(`server-${s}`, { fishing: { plus: { fish: 10 } } });
    }

    for (let s = 0; s < 20; s++) {
      await wider.publish(`server-${s}`, { fishing: { plus: { fish: 11 }, minus: {} } }, clock);
    }

    expect((await wider.read("fishing", clock))?.totals.fish).toBe(220);
    expect((await store.read("fishing", clock))?.totals.fish).toBe(220);
  });

  it("counts a player's own vote entry in the totals but not as an active server", async () => {
    await create("boss_vote", { options: ["kraken", "megalodon"] });
    await publish("server-a", { boss_vote: {} });
    await publish("v-1001", { boss_vote: { plus: { kraken: 1, megalodon: 1 }, minus: { kraken: 1 } } });
    const again = await publish("v-1001", { boss_vote: { plus: { kraken: 1, megalodon: 1 }, minus: { kraken: 1 } } });
    expect(again.events.boss_vote.totals).toEqual({ kraken: 0, megalodon: 1 });
    expect(again.events.boss_vote.servers).toBe(1);
  });

  it("marks a goal in the batch that crosses it, even on an instance whose cached shard totals are old", async () => {
    const names: string[] = [];
    const used = new Set<number>();
    for (let n = 0; names.length < 3; n++) {
      const shard = shardOf(`g${n}`, config.shards);
      if (!used.has(shard)) {
        used.add(shard);
        names.push(`g${n}`);
      }
    }

    const slow = new EventStore(redis, { closeGraceSeconds: 60, shards: config.shards, refreshMs: 60_000, clock: () => 0 });
    await create("fishing", { options: ["fish"], goal: { option: "fish", target: 10 } });
    await slow.publish(names[0] as string, { fishing: { plus: { fish: 6 }, minus: {} } }, clock);
    await publish(names[1] as string, { fishing: { plus: { fish: 3 } } });
    clock = 1_005;
    const crossing = await slow.publish(names[2] as string, { fishing: { plus: { fish: 1 }, minus: {} } }, clock);
    expect(crossing.fishing?.totals.fish).toBe(10);
    expect(crossing.fishing?.state).toBe("completed");
    expect(crossing.fishing?.completedAt).toBe(1_005);
  });

  it("counts only servers seen in the last 30 seconds as active", async () => {
    await create("fishing", { options: ["fish"] });
    await publish("old", { fishing: { plus: { fish: 1 } } });
    clock = 1_100;
    const result = await publish("new", { fishing: { plus: { fish: 1 } } });
    expect(result.events.fishing.servers).toBe(1);
    expect(result.events.fishing.totals.fish).toBe(2);
  });
});
