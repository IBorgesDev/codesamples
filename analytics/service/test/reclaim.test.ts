import type { Redis } from "ioredis";
import { describe, expect, it } from "vitest";
import { dedupToken } from "../src/pipeline.js";
import { compareIds, deadConsumer, pendingEntries, RedisShardStream, trimFloor } from "../src/stream.js";

const KEY = "analytics:events:{0}";
const IDLE_MS = 60_000;
const COUNT = 200;

type Pending = { id: string; consumer: string; idleMs: number; deliveries: number };

class FakePendingRedis {
  readonly calls: string[] = [];

  constructor(private readonly pending: Pending[]) {}

  async call(command: string, ...args: (string | number)[]): Promise<unknown> {
    this.calls.push(command);
    if (command === "XPENDING") {
      const minIdle = Number(args[3]);
      const count = Number(args[6]);
      const consumer = args[7] === undefined ? null : String(args[7]);
      return this.pending
        .filter((entry) => entry.idleMs >= minIdle && (consumer === null || entry.consumer === consumer))
        .sort((a, b) => a.id.localeCompare(b.id))
        .slice(0, count)
        .map((entry) => [entry.id, entry.consumer, entry.idleMs, entry.deliveries]);
    }

    if (command === "XCLAIM") {
      const claimer = String(args[2]);
      const minIdle = Number(args[3]);
      const ids = args.slice(4).map(String);
      const claimed: unknown[] = [];
      for (const id of ids) {
        const entry = this.pending.find((candidate) => candidate.id === id);
        if (entry && entry.idleMs >= minIdle) {
          entry.consumer = claimer;
          entry.idleMs = 0;
          entry.deliveries += 1;
          claimed.push([id, ["batch", `{"id":"${id}"}`]]);
        }
      }

      return claimed;
    }

    throw new Error(`unexpected ${command}`);
  }
}

function stream(redis: FakePendingRedis, consumer: string): RedisShardStream {
  return new RedisShardStream(redis as unknown as Redis, KEY, consumer);
}

function pending(consumer: string, ids: string[], idleMs = IDLE_MS * 2): Pending[] {
  return ids.map((id) => ({ id, consumer, idleMs, deliveries: 1 }));
}

describe("reclaiming a dead consumer's entries", () => {
  it("takes back one dead consumer's whole group at a time, so each insert keeps its original token", async () => {
    const groupA = ["1-0", "2-0", "3-0"];
    const groupB = ["4-0", "5-0"];
    const redis = new FakePendingRedis([...pending("worker-a", groupA), ...pending("worker-b", groupB)]);
    const survivor = stream(redis, "worker-c");

    const first = await survivor.reclaim(IDLE_MS, COUNT);
    expect(first.map((entry) => entry.id)).toEqual(groupA);
    expect(dedupToken(KEY, first.map((entry) => entry.id))).toBe(dedupToken(KEY, groupA));

    const second = await survivor.reclaim(IDLE_MS, COUNT);
    expect(second.map((entry) => entry.id)).toEqual(groupB);
    expect(dedupToken(KEY, second.map((entry) => entry.id))).toBe(dedupToken(KEY, groupB));

    expect(await survivor.reclaim(IDLE_MS, COUNT)).toEqual([]);
  });

  it("never merges two dead consumers whose entries interleave in the stream", async () => {
    const redis = new FakePendingRedis([
      ...pending("worker-a", ["1-0", "3-0", "5-0"]),
      ...pending("worker-b", ["2-0", "4-0"]),
    ]);

    const first = await stream(redis, "worker-c").reclaim(IDLE_MS, COUNT);
    expect(first.map((entry) => entry.id)).toEqual(["1-0", "3-0", "5-0"]);
  });

  it("leaves its own entries and entries that are not idle yet", async () => {
    const redis = new FakePendingRedis([
      ...pending("worker-c", ["1-0"]),
      ...pending("worker-a", ["2-0"], IDLE_MS / 2),
    ]);

    expect(await stream(redis, "worker-c").reclaim(IDLE_MS, COUNT)).toEqual([]);
    expect(redis.calls).toEqual(["XPENDING"]);
  });

  it("reads XPENDING replies defensively", () => {
    expect(pendingEntries(null)).toEqual([]);
    expect(pendingEntries([["1-0", "worker-a", 61_000, 1], "junk", ["2-0"]])).toEqual([
      { id: "1-0", consumer: "worker-a", idleMs: 61_000 },
    ]);
    expect(deadConsumer([{ id: "1-0", consumer: "self", idleMs: 1 }], "self")).toBeNull();
  });
});

describe("stream trimming floor", () => {
  it("orders stream ids by time, then sequence", () => {
    expect(compareIds("10-2", "10-10")).toBeLessThan(0);
    expect(compareIds("11-0", "10-99")).toBeGreaterThan(0);
    expect(compareIds("5-1", "5-1")).toBe(0);
  });

  it("keeps everything from the oldest pending entry, or after the last delivered one, across groups", () => {
    expect(trimFloor([{ lastDelivered: "90-0", pending: 3, oldestPending: "40-1" }])).toBe("40-1");
    expect(trimFloor([{ lastDelivered: "90-0", pending: 0, oldestPending: null }])).toBe("90-0");
    expect(
      trimFloor([
        { lastDelivered: "90-0", pending: 0, oldestPending: null },
        { lastDelivered: "70-5", pending: 0, oldestPending: null },
      ]),
    ).toBe("70-5");
  });

  it("trims nothing before any group has read anything", () => {
    expect(trimFloor([{ lastDelivered: "0-0", pending: 0, oldestPending: null }])).toBe(null);
    expect(trimFloor([])).toBe(null);
  });
});
