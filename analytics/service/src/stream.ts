import type { Redis } from "ioredis";
import { CONSUMER_GROUP } from "./keys.js";
import type { ShardEntry, ShardStream } from "./pipeline.js";
import { entries, isBusyGroup } from "./redis.js";

export type PendingEntry = { id: string; consumer: string; idleMs: number };

export function pendingEntries(reply: unknown): PendingEntry[] {
  if (!Array.isArray(reply)) {
    return [];
  }

  const out: PendingEntry[] = [];
  for (const item of reply) {
    if (Array.isArray(item) && item.length >= 3) {
      out.push({ id: String(item[0]), consumer: String(item[1]), idleMs: Number(item[2]) });
    }
  }

  return out;
}

export function deadConsumer(idle: PendingEntry[], self: string): string | null {
  return idle.find((entry) => entry.consumer !== self)?.consumer ?? null;
}

function streamEntries(reply: unknown): ShardEntry[] {
  if (!Array.isArray(reply) || !Array.isArray(reply[0])) {
    return [];
  }

  return entries(reply[0][1]);
}

export class RedisShardStream implements ShardStream {
  constructor(
    private readonly redis: Redis,
    readonly key: string,
    private readonly consumer: string,
    private readonly group = CONSUMER_GROUP,
  ) {}

  async ensureGroup(): Promise<void> {
    try {
      await this.redis.call("XGROUP", "CREATE", this.key, this.group, "0", "MKSTREAM");
    } catch (error) {
      if (!isBusyGroup(error)) {
        throw error;
      }
    }
  }

  async readPending(count: number): Promise<ShardEntry[]> {
    const reply = await this.redis.call("XREADGROUP", "GROUP", this.group, this.consumer, "COUNT", count, "STREAMS", this.key, "0");
    return streamEntries(reply);
  }

  async readNew(count: number, blockMs: number): Promise<ShardEntry[]> {
    const reply = await this.redis.call(
      "XREADGROUP",
      "GROUP",
      this.group,
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

  async reclaim(minIdleMs: number, count: number): Promise<ShardEntry[]> {
    const idle = pendingEntries(await this.redis.call("XPENDING", this.key, this.group, "IDLE", minIdleMs, "-", "+", count));
    const owner = deadConsumer(idle, this.consumer);
    if (owner === null) {
      return [];
    }

    const owned = pendingEntries(
      await this.redis.call("XPENDING", this.key, this.group, "IDLE", minIdleMs, "-", "+", count, owner),
    );
    if (owned.length === 0) {
      return [];
    }

    const ids = owned.map((entry) => entry.id);
    return entries(await this.redis.call("XCLAIM", this.key, this.group, this.consumer, minIdleMs, ...ids));
  }

  async touch(ids: string[]): Promise<void> {
    if (ids.length > 0) {
      await this.redis.call("XCLAIM", this.key, this.group, this.consumer, 0, ...ids, "JUSTID");
    }
  }

  async ack(ids: string[]): Promise<void> {
    if (ids.length > 0) {
      await this.redis.call("XACK", this.key, this.group, ...ids);
    }
  }
}
