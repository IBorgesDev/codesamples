import { hostname } from "node:os";
import { fileURLToPath } from "node:url";

export type ClickHouseConfig = {
  url: string;
  user: string;
  password: string;
  timeoutMs: number;
};

export type IngestConfig = {
  port: number;
  redisUrl: string;
  serverToken: string;
  readToken: string;
  schemaPath: string;
  streamShards: number;
  streamMaxLen: number;
  maxBacklog: number;
  dedupeTtlSeconds: number;
  retryAfterSeconds: number;
  eventMaxAgeSeconds: number;
  eventMaxAheadSeconds: number;
  statsMaxMinutes: number;
  clickhouse: ClickHouseConfig;
};

export type WorkerConfig = {
  port: number;
  redisUrl: string;
  streamShards: number;
  consumer: string;
  readCount: number;
  blockMs: number;
  claimIdleMs: number;
  reclaimEveryMs: number;
  backoffBaseMs: number;
  backoffMaxMs: number;
  clickhouse: ClickHouseConfig;
};

const DEFAULT_SCHEMA_PATH = fileURLToPath(new URL("../../schema/events.json", import.meta.url));

function required(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`missing environment variable ${name}`);
  }

  return value;
}

function text(name: string, fallback: string): string {
  return process.env[name] || fallback;
}

function integer(name: string, fallback: number, minimum = 1): number {
  const raw = process.env[name];
  if (raw === undefined) {
    return fallback;
  }

  const value = Number(raw);
  if (!Number.isInteger(value) || value < minimum) {
    throw new Error(`${name} must be an integer >= ${minimum}`);
  }

  return value;
}

function clickhouse(): ClickHouseConfig {
  return {
    url: text("CLICKHOUSE_URL", "http://localhost:8123"),
    user: text("CLICKHOUSE_USER", "default"),
    password: process.env.CLICKHOUSE_PASSWORD ?? "",
    timeoutMs: integer("CLICKHOUSE_TIMEOUT_MS", 10_000),
  };
}

export function loadIngestConfig(): IngestConfig {
  const config: IngestConfig = {
    port: integer("PORT", 8080),
    redisUrl: required("REDIS_URL"),
    serverToken: required("ANALYTICS_SERVER_TOKEN"),
    readToken: required("ANALYTICS_READ_TOKEN"),
    schemaPath: text("ANALYTICS_SCHEMA_PATH", DEFAULT_SCHEMA_PATH),
    streamShards: integer("ANALYTICS_STREAM_SHARDS", 4),
    streamMaxLen: integer("ANALYTICS_STREAM_MAXLEN", 40_000),
    maxBacklog: integer("ANALYTICS_MAX_BACKLOG", 20_000),
    dedupeTtlSeconds: integer("ANALYTICS_DEDUPE_TTL_SECONDS", 3_600),
    retryAfterSeconds: integer("ANALYTICS_RETRY_AFTER_SECONDS", 5),
    eventMaxAgeSeconds: integer("ANALYTICS_EVENT_MAX_AGE_SECONDS", 86_400),
    eventMaxAheadSeconds: integer("ANALYTICS_EVENT_MAX_AHEAD_SECONDS", 300),
    statsMaxMinutes: integer("ANALYTICS_STATS_MAX_MINUTES", 1_440),
    clickhouse: clickhouse(),
  };

  if (config.streamMaxLen < 2 * config.maxBacklog) {
    throw new Error("ANALYTICS_STREAM_MAXLEN must be at least twice ANALYTICS_MAX_BACKLOG, so trimming never reaches unread entries");
  }

  return config;
}

export function loadWorkerConfig(): WorkerConfig {
  const config: WorkerConfig = {
    port: integer("PORT", 8080),
    redisUrl: required("REDIS_URL"),
    streamShards: integer("ANALYTICS_STREAM_SHARDS", 4),
    consumer: text("ANALYTICS_WORKER_CONSUMER", hostname()),
    readCount: integer("ANALYTICS_WORKER_READ_COUNT", 200),
    blockMs: integer("ANALYTICS_WORKER_BLOCK_MS", 1_000),
    claimIdleMs: integer("ANALYTICS_WORKER_CLAIM_IDLE_MS", 60_000),
    reclaimEveryMs: integer("ANALYTICS_WORKER_RECLAIM_EVERY_MS", 15_000),
    backoffBaseMs: integer("ANALYTICS_WORKER_BACKOFF_BASE_MS", 250),
    backoffMaxMs: integer("ANALYTICS_WORKER_BACKOFF_MAX_MS", 15_000),
    clickhouse: clickhouse(),
  };

  if ((config.backoffMaxMs + config.clickhouse.timeoutMs) * 2 > config.claimIdleMs) {
    throw new Error(
      "ANALYTICS_WORKER_BACKOFF_MAX_MS plus CLICKHOUSE_TIMEOUT_MS must stay within half of ANALYTICS_WORKER_CLAIM_IDLE_MS, so a retrying worker keeps its entries",
    );
  }

  return config;
}
