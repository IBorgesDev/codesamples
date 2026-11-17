import { Cluster, Redis } from "ioredis";
import { buildApp } from "./app.js";
import { type Batch, Coalescer } from "./coalescer.js";
import { loadConfig } from "./config.js";
import { logger } from "./log.js";
import { ignoredOptions } from "./metrics.js";
import { EventStore, type RedisClient } from "./store.js";

const MILLISECONDS = 1000;

const log = logger("events");
const config = loadConfig();
const clustered = config.redisClusterNodes.length > 0;
const redis: RedisClient = clustered
  ? new Cluster(config.redisClusterNodes, {
      enableAutoPipelining: true,
      redisOptions: { password: config.redisPassword, maxRetriesPerRequest: 2 },
    })
  : new Redis(config.redisUrl, { enableAutoPipelining: true, maxRetriesPerRequest: 2 });
redis.on("error", (error) => log("redis connection", error));
const store = new EventStore(redis, {
  closeGraceSeconds: config.closeGraceSeconds,
  shards: config.shards,
  refreshMs: config.totalsRefreshMs,
  activeWindowSeconds: config.activeWindowSeconds,
});
const now = () => Math.floor(Date.now() / MILLISECONDS);

async function publishBatch(batch: Batch) {
  const snapshots = await store.publishBatch(batch, now());
  for (const snapshot of snapshots.values()) {
    ignoredOptions.inc(snapshot?.ignored ?? 0);
  }

  return snapshots;
}

const coalescer = config.batchMs > 0 ? new Coalescer(publishBatch, config.batchMs, config.batchMaxRequests, config.batchMaxFields) : undefined;
const app = buildApp({ store, redis, config, coalescer, now, log });

async function shutdown(signal: string) {
  console.log(`events: ${signal}, closing`);
  await app.close();
  redis.disconnect();
  process.exit(0);
}

process.on("SIGTERM", () => void shutdown("SIGTERM"));
process.on("SIGINT", () => void shutdown("SIGINT"));

await app.listen({ host: "0.0.0.0", port: config.port });
console.log(`events: listening on ${config.port} with ${config.shards} shards per event${clustered ? " on a Redis Cluster" : ""}`);
