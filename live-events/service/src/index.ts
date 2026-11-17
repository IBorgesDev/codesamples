import { Cluster, Redis } from "ioredis";
import { buildApp } from "./app.js";
import { Coalescer } from "./coalescer.js";
import { loadConfig } from "./config.js";
import { EventStore, type RedisClient } from "./store.js";

const config = loadConfig();
const password = decodeURIComponent(new URL(config.redisUrl).password);
const redis: RedisClient =
  config.redisClusterNodes.length > 0
    ? new Cluster(
        config.redisClusterNodes.map((node) => {
          const [host, port] = node.split(":");
          return { host: host as string, port: Number(port) };
        }),
        { enableAutoPipelining: true, redisOptions: { password, maxRetriesPerRequest: 2 } },
      )
    : new Redis(config.redisUrl, { enableAutoPipelining: true, maxRetriesPerRequest: 2 });
const store = new EventStore(redis, {
  closeGraceSeconds: config.closeGraceSeconds,
  shards: config.shards,
  refreshMs: config.totalsRefreshMs,
});
const now = () => Math.floor(Date.now() / 1000);
const coalescer = config.batchMs > 0 ? new Coalescer((batch) => store.publishBatch(batch, now()), config.batchMs, config.batchMax) : undefined;
const app = buildApp({ store, redis, config, coalescer, now });

async function shutdown(signal: string) {
  console.log(`events: ${signal}, closing`);
  await app.close();
  redis.disconnect();
  process.exit(0);
}

process.on("SIGTERM", () => void shutdown("SIGTERM"));
process.on("SIGINT", () => void shutdown("SIGINT"));

await app.listen({ host: "0.0.0.0", port: config.port });
console.log(`events: listening on ${config.port} with ${config.shards} shards per event${config.redisClusterNodes.length > 0 ? " on a Redis Cluster" : ""}`);
