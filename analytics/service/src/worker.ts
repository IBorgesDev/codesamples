import Fastify from "fastify";
import { Redis } from "ioredis";
import { ClickHouse } from "./clickhouse.js";
import { loadWorkerConfig } from "./config.js";
import { streamKey } from "./keys.js";
import { createRegistry, createWorkerMetrics } from "./metrics.js";
import { type RowSink, ShardWorker } from "./pipeline.js";
import { RedisShardStream } from "./stream.js";

const EVENTS_TABLE = "analytics.events";
const STALE_AFTER_MS = 60_000;
const STOP_GRACE_MS = 10_000;

const config = loadWorkerConfig();
const redis = new Redis(config.redisUrl, { maxRetriesPerRequest: 2 });
const clickhouse = new ClickHouse(config.clickhouse);
const metrics = createWorkerMetrics(createRegistry(true));
const sink: RowSink = { insert: (rows, token) => clickhouse.insert(EVENTS_TABLE, rows, token) };
const connections = Array.from({ length: config.streamShards }, () => redis.duplicate());
const workers = connections.map(
  (connection, shard) =>
    new ShardWorker(new RedisShardStream(connection, streamKey(shard), config.consumer), sink, metrics, {
      readCount: config.readCount,
      blockMs: config.blockMs,
      claimIdleMs: config.claimIdleMs,
      reclaimEveryMs: config.reclaimEveryMs,
      backoffBaseMs: config.backoffBaseMs,
      backoffMaxMs: config.backoffMaxMs,
    }),
);

const controller = new AbortController();
const runs = workers.map((worker) => worker.run(controller.signal));

const app = Fastify({ logger: false });

app.get("/healthz", async (_request, reply) => {
  const pong = await redis.ping().catch(() => null);
  const alive = workers.every((worker) => Date.now() - worker.lastBeatAt() < STALE_AFTER_MS);
  const healthy = pong === "PONG" && alive;
  return reply.code(healthy ? 200 : 503).send({ redis: pong === "PONG", shards: alive });
});

app.get("/metrics", async (_request, reply) => {
  return reply.type(metrics.registry.contentType).send(await metrics.registry.metrics());
});

async function shutdown(signal: string) {
  console.log(`analytics-worker: ${signal}, finishing the current inserts`);
  controller.abort();
  await Promise.race([Promise.allSettled(runs), new Promise((resolve) => setTimeout(resolve, STOP_GRACE_MS))]);
  await app.close();
  for (const connection of connections) {
    connection.disconnect();
  }

  redis.disconnect();
  process.exit(0);
}

process.on("SIGTERM", () => void shutdown("SIGTERM"));
process.on("SIGINT", () => void shutdown("SIGINT"));

await app.listen({ host: "0.0.0.0", port: config.port });
console.log(`analytics-worker: consumer ${config.consumer} on ${config.streamShards} shards, metrics on ${config.port}`);
