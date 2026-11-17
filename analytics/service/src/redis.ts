import { createHash } from "node:crypto";
import type { Redis } from "ioredis";
import { CONSUMER_GROUP } from "./keys.js";

export type Runner = (keys: string[], args: (string | number)[]) => Promise<unknown>;

export type StreamEntry = { id: string; batch: string | null };

export function script(redis: Redis, lua: string): Runner {
  const sha = createHash("sha1").update(lua).digest("hex");
  return async (keys, args) => {
    try {
      return await redis.evalsha(sha, keys.length, ...keys, ...args);
    } catch (error) {
      if (!String(error).includes("NOSCRIPT")) {
        throw error;
      }

      return redis.eval(lua, keys.length, ...keys, ...args);
    }
  };
}

export function flatRecord(reply: unknown): Map<string, unknown> {
  const out = new Map<string, unknown>();
  const list = Array.isArray(reply) ? reply : [];
  for (let i = 0; i + 1 < list.length; i += 2) {
    out.set(String(list[i]), list[i + 1]);
  }

  return out;
}

export function entries(reply: unknown): StreamEntry[] {
  const list = Array.isArray(reply) ? reply : [];
  const out: StreamEntry[] = [];
  for (const item of list) {
    if (!Array.isArray(item) || item.length < 1) {
      continue;
    }

    const fields = Array.isArray(item[1]) ? flatRecord(item[1]) : null;
    const batch = fields?.get("batch");
    out.push({ id: String(item[0]), batch: typeof batch === "string" ? batch : null });
  }

  return out;
}

export function isMissingKey(error: unknown): boolean {
  return String(error).includes("no such key");
}

export function isMissingGroup(error: unknown): boolean {
  return String(error).includes("NOGROUP");
}

export async function ensureGroup(redis: Redis, key: string): Promise<void> {
  try {
    await redis.call("XGROUP", "CREATE", key, CONSUMER_GROUP, "0", "MKSTREAM");
  } catch (error) {
    if (!String(error).includes("BUSYGROUP")) {
      throw error;
    }
  }
}
