import type { Redis } from "ioredis";
import { CONSUMER_GROUP } from "./keys.js";
import type { ShardEntry, ShardStream } from "./pipeline.js";
import { entries, flatRecord, isBusyGroup } from "./redis.js";

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

export type GroupState = { lastDelivered: string; pending: number; oldestPending: string | null };

export function compareIds(left: string, right: string): number {
  const [leftMs = 0, leftSeq = 0] = left.split("-").map(Number);
  const [rightMs = 0, rightSeq = 0] = right.split("-").map(Number);
  return leftMs === rightMs ? leftSeq - rightSeq : leftMs - rightMs;
}

export function trimFloor(groups: GroupState[]): string | null {
  let floor: string | null = null;
  for (const group of groups) {
    const needed = group.pending > 0 && group.oldestPending !== null ? group.oldestPending : group.lastDelivered;
    if (floor === null || compareIds(needed, floor) < 0) {
      floor = needed;
    }
  }

  return floor === null || compareIds(floor, "0-0") <= 0 ? null : floor;
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
      await this.trim().catch(() => undefined);
    }
  }

  async trim(): Promise<string | null> {
    const groups: GroupState[] = [];
    for (const raw of (await this.redis.call("XINFO", "GROUPS", this.key)) as unknown[]) {
      const fields = flatRecord(raw);
      const name = String(fields.get("name"));
      const summary = (await this.redis.call("XPENDING", this.key, name)) as unknown[];
      groups.push({
        lastDelivered: String(fields.get("last-delivered-id") ?? "0-0"),
        pending: Number(summary[0] ?? 0),
        oldestPending: summary[1] === null || summary[1] === undefined ? null : String(summary[1]),
      });
    }

    const floor = trimFloor(groups);
    if (floor !== null) {
      await this.redis.call("XTRIM", this.key, "MINID", "~", floor);
    }

    return floor;
  }
}
