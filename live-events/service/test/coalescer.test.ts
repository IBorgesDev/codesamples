import { describe, expect, it } from "vitest";
import { type Batch, Coalescer } from "../src/coalescer.js";
import type { Snapshot } from "../src/store.js";

function snapshot(fish: number): Snapshot {
  return { state: "live", version: 1, totals: { fish }, completedAt: null, endsAt: null, servers: 1, ignored: 0 };
}

describe("coalescer", () => {
  it("merges many requests into one flush, keeping the highest value per server and option", async () => {
    const flushed: Batch[] = [];
    const coalescer = new Coalescer(async (batch) => {
      flushed.push(batch);
      return new Map([["fishing", snapshot(15)]]);
    }, 5, 1000);

    const results = await Promise.all([
      coalescer.add("s1", { fishing: { plus: { fish: 4 }, minus: {} } }),
      coalescer.add("s1", { fishing: { plus: { fish: 9 }, minus: {} } }),
      coalescer.add("s1", { fishing: { plus: { fish: 7 }, minus: {} } }),
      coalescer.add("s2", { fishing: { plus: { fish: 6 }, minus: {} } }),
    ]);

    expect(flushed).toHaveLength(1);
    expect(flushed[0]?.get("fishing")?.get("s1")?.plus.fish).toBe(9);
    expect(flushed[0]?.get("fishing")?.get("s2")?.plus.fish).toBe(6);
    for (const result of results) {
      expect(result.get("fishing")?.totals.fish).toBe(15);
    }
  });

  it("answers only after the batch holding the request is written", async () => {
    let written = false;
    const coalescer = new Coalescer(async () => {
      await new Promise((resolve) => setTimeout(resolve, 20));
      written = true;
      return new Map();
    }, 5, 1000);

    await coalescer.add("s1", { fishing: { plus: { fish: 1 }, minus: {} } });
    expect(written).toBe(true);
  });

  it("fails every request of a batch the store rejected, so the servers resend", async () => {
    const coalescer = new Coalescer(async () => {
      throw new Error("redis down");
    }, 5, 1000);

    const outcomes = await Promise.allSettled([
      coalescer.add("s1", { fishing: { plus: { fish: 1 }, minus: {} } }),
      coalescer.add("s2", { fishing: { plus: { fish: 2 }, minus: {} } }),
    ]);

    expect(outcomes.every((outcome) => outcome.status === "rejected")).toBe(true);
    expect(coalescer.pending()).toBe(0);
  });

  it("flushes at once when a batch reaches its size limit", async () => {
    let flushes = 0;
    const coalescer = new Coalescer(async () => {
      flushes += 1;
      return new Map();
    }, 10_000, 3);

    await Promise.all([1, 2, 3].map((n) => coalescer.add(`s${n}`, { fishing: { plus: { fish: n }, minus: {} } })));
    expect(flushes).toBe(1);
  });
});
