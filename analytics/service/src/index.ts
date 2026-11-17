import { Redis } from "ioredis";
import { buildApp } from "./app.js";
import { loadCatalog } from "./catalog.js";
import { ClickHouse } from "./clickhouse.js";
import { loadIngestConfig } from "./config.js";
import { createIngestMetrics, createRegistry } from "./metrics.js";
import { ClickHouseStats } from "./stats.js";
import { RedisBatchStore } from "./store.js";

const config = loadIngestConfig();
const catalog = loadCatalog(config.schemaPath);
const redis = new Redis(config.redisUrl, { enableAutoPipelining: true, maxRetriesPerRequest: 2 });
const store = new RedisBatchStore(redis, {
  shards: config.streamShards,
  dedupeTtlSeconds: config.dedupeTtlSeconds,
});
const stats = new ClickHouseStats(new ClickHouse(config.clickhouse));
const metrics = createIngestMetrics(createRegistry(true));
const app = buildApp({ config, catalog, store, stats, metrics });

store.ensureGroups().catch((error) => console.error("analytics: could not create consumer groups yet", error));

async function shutdown(signal: string) {
  console.log(`analytics: ${signal}, closing`);
  await app.close();
  redis.disconnect();
  process.exit(0);
}

process.on("SIGTERM", () => void shutdown("SIGTERM"));
process.on("SIGINT", () => void shutdown("SIGINT"));

await app.listen({ host: "0.0.0.0", port: config.port });
console.log(`analytics: listening on ${config.port}, ${catalog.events.size} event types, ${config.streamShards} shards`);
