import type { Redis } from "ioredis";
import { CONSUMER_GROUP, seenKey, shardOf, streamKey } from "./keys.js";
import { flatRecord, isBusyGroup, isMissingKey, type Runner, script } from "./redis.js";
import { APPEND_BATCH } from "./scripts.js";

export type AppendResult = "appended" | "duplicate";

export interface BatchStore {
  append(serverId: string, batchSeq: number, payload: string): Promise<AppendResult>;
  backlog(): Promise<number>;
  healthy(): Promise<boolean>;
}

export type RedisBatchStoreOptions = {
  shards: number;
  dedupeTtlSeconds: number;
};

export class RedisBatchStore implements BatchStore {
  private readonly runAppend: Runner;

  constructor(
    private readonly redis: Redis,
    private readonly options: RedisBatchStoreOptions,
  ) {
    this.runAppend = script(redis, APPEND_BATCH);
  }

  async ensureGroups(): Promise<void> {
    for (let shard = 0; shard < this.options.shards; shard++) {
      try {
        await this.redis.call("XGROUP", "CREATE", streamKey(shard), CONSUMER_GROUP, "0", "MKSTREAM");
      } catch (error) {
        if (!isBusyGroup(error)) {
          throw error;
        }
      }
    }
  }

  async append(serverId: string, batchSeq: number, payload: string): Promise<AppendResult> {
    const shard = shardOf(serverId, this.options.shards);
    const added = await this.runAppend(
      [seenKey(shard, serverId, batchSeq), streamKey(shard)],
      [this.options.dedupeTtlSeconds, payload],
    );

    return Number(added) === 1 ? "appended" : "duplicate";
  }

  async backlog(): Promise<number> {
    const perShard = await Promise.all(
      Array.from({ length: this.options.shards }, (_, shard) => this.shardBacklog(streamKey(shard))),
    );

    return perShard.reduce((sum, value) => sum + value, 0);
  }

  async healthy(): Promise<boolean> {
    return (await this.redis.ping().catch(() => null)) === "PONG";
  }

  private async shardBacklog(key: string): Promise<number> {
    let reply: unknown;
    try {
      reply = await this.redis.call("XINFO", "GROUPS", key);
    } catch (error) {
      if (isMissingKey(error)) {
        return 0;
      }

      throw error;
    }

    const groups = (Array.isArray(reply) ? reply : []).map(flatRecord);
    const group = groups.find((fields) => fields.get("name") === CONSUMER_GROUP);
    const lag = group?.get("lag");
    if (group === undefined || lag === null || lag === undefined) {
      return this.redis.xlen(key);
    }

    return Number(lag) + Number(group.get("pending") ?? 0);
  }
}
