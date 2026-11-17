import type { Redis } from "ioredis";
import { CONSUMER_GROUP } from "./keys.js";
import type { ShardStream } from "./pipeline.js";
import { ensureGroup, entries, flatRecord, type StreamEntry } from "./redis.js";

type PendingEntry = { id: string; consumer: string };

const FIRST_ID = "0-0";

function pendingEntries(reply: unknown): PendingEntry[] {
  if (!Array.isArray(reply)) {
    return [];
  }

  const out: PendingEntry[] = [];
  for (const item of reply) {
    if (Array.isArray(item) && item.length >= 2) {
      out.push({ id: String(item[0]), consumer: String(item[1]) });
    }
  }

  return out;
}

function streamEntries(reply: unknown): StreamEntry[] {
  if (!Array.isArray(reply) || !Array.isArray(reply[0])) {
    return [];
  }

  return entries(reply[0][1]);
}

function compareIds(left: string, right: string): number {
  const [leftMs = 0, leftSeq = 0] = left.split("-").map(Number);
  const [rightMs = 0, rightSeq = 0] = right.split("-").map(Number);
  return leftMs === rightMs ? leftSeq - rightSeq : leftMs - rightMs;
}

export class RedisShardStream implements ShardStream {
  constructor(
    private readonly redis: Redis,
    readonly key: string,
    private readonly rejectedKey: string,
    private readonly consumer: string,
    private readonly rejectedKept: number,
  ) {}

  ensureGroup(): Promise<void> {
    return ensureGroup(this.redis, this.key);
  }

  async readPending(count: number): Promise<StreamEntry[]> {
    const reply = await this.redis.call("XREADGROUP", "GROUP", CONSUMER_GROUP, this.consumer, "COUNT", count, "STREAMS", this.key, "0");
    return streamEntries(reply);
  }

  async readNew(count: number, blockMs: number): Promise<StreamEntry[]> {
    const reply = await this.redis.call(
      "XREADGROUP",
      "GROUP",
      CONSUMER_GROUP,
      this.consumer,
      "COUNT",
      count,
      "BLOCK",
      blockMs,
      "STREAMS",
      this.key,
      ">",
    );
    return streamEntries(reply);
  }

  async reclaim(minIdleMs: number, count: number): Promise<StreamEntry[]> {
    const idle = pendingEntries(await this.redis.call("XPENDING", this.key, CONSUMER_GROUP, "IDLE", minIdleMs, "-", "+", count));
    const owner = idle.find((entry) => entry.consumer !== this.consumer)?.consumer;
    if (owner === undefined) {
      return [];
    }

    const owned = pendingEntries(
      await this.redis.call("XPENDING", this.key, CONSUMER_GROUP, "IDLE", minIdleMs, "-", "+", count, owner),
    );
    if (owned.length === 0) {
      return [];
    }

    const ids = owned.map((entry) => entry.id);
    return entries(await this.redis.call("XCLAIM", this.key, CONSUMER_GROUP, this.consumer, minIdleMs, ...ids));
  }

  async touch(ids: string[]): Promise<void> {
    if (ids.length > 0) {
      await this.redis.call("XCLAIM", this.key, CONSUMER_GROUP, this.consumer, 0, ...ids, "JUSTID");
    }
  }

  async ack(ids: string[]): Promise<void> {
    if (ids.length > 0) {
      await this.redis.call("XACK", this.key, CONSUMER_GROUP, ...ids);
    }
  }

  async setAside(entry: StreamEntry): Promise<void> {
    await this.redis.call("XADD", this.rejectedKey, "MAXLEN", "~", this.rejectedKept, "*", "id", entry.id, "batch", entry.batch ?? "");
  }

  async trim(): Promise<void> {
    const group = (await this.groups()).map(flatRecord).find((fields) => fields.get("name") === CONSUMER_GROUP);
    if (group === undefined) {
      return;
    }

    const summary = await this.redis.call("XPENDING", this.key, CONSUMER_GROUP);
    const oldestPending = Array.isArray(summary) && Number(summary[0] ?? 0) > 0 && typeof summary[1] === "string" ? summary[1] : null;
    const floor = oldestPending ?? String(group.get("last-delivered-id") ?? FIRST_ID);
    if (compareIds(floor, FIRST_ID) > 0) {
      await this.redis.call("XTRIM", this.key, "MINID", "~", floor);
    }
  }

  private async groups(): Promise<unknown[]> {
    const reply = await this.redis.call("XINFO", "GROUPS", this.key);
    return Array.isArray(reply) ? reply : [];
  }
}
