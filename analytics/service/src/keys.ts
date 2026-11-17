export const CONSUMER_GROUP = "clickhouse";

const FNV_OFFSET = 0x811c9dc5;
const FNV_PRIME = 0x01000193;

function fnv1a32(text: string): number {
  let hash = FNV_OFFSET;
  for (const byte of Buffer.from(text, "utf8")) {
    hash = Math.imul(hash ^ byte, FNV_PRIME);
  }

  return hash >>> 0;
}

export function shardOf(serverId: string, shards: number): number {
  return fnv1a32(serverId) % shards;
}

export function streamKey(shard: number): string {
  return `analytics:events:{${shard}}`;
}

export function rejectedKey(shard: number): string {
  return `analytics:rejected:{${shard}}`;
}

export function seenKey(shard: number, serverId: string, batchSeq: number): string {
  return `analytics:seen:{${shard}}:${serverId}:${batchSeq}`;
}
