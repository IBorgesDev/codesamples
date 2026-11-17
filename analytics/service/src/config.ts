import { hostname } from "node:os";
import { fileURLToPath } from "node:url";

export type ClickHouseConfig = {
  url: string;
  user: string;
  password: string;
  timeoutMs: number;
  maxResultRows: number;
};

type SharedConfig = {
  port: number;
  redisUrl: string;
  streamShards: number;
  clickhouse: ClickHouseConfig;
};

export type IngestConfig = SharedConfig & {
  serverToken: string;
  readToken: string;
  schemaPath: string;
  maxBacklog: number;
  backlogRefreshMs: number;
  dedupeTtlSeconds: number;
  retryAfterSeconds: number;
  requestTimeoutMs: number;
  eventMaxAgeSeconds: number;
  eventMaxAheadSeconds: number;
  statsMaxMinutes: number;
};

export type WorkerConfig = SharedConfig & {
  consumer: string;
  readCount: number;
  blockMs: number;
  claimIdleMs: number;
  reclaimEveryMs: number;
  backoffBaseMs: number;
  backoffMaxMs: number;
  rejectedKept: number;
  staleAfterMs: number;
  stopGraceMs: number;
};

const DEFAULT_SCHEMA_PATH = fileURLToPath(new URL("../../schema/events.json", import.meta.url));
const MIN_TOKEN_CHARS = 32;

function required(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`missing environment variable ${name}`);
  }

  return value;
}

function token(name: string): string {
  const value = required(name);
  if (value.length < MIN_TOKEN_CHARS) {
    throw new Error(`${name} must have at least ${MIN_TOKEN_CHARS} characters`);
  }

  return value;
}

function optional(name: string, fallback: string): string {
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

function shared(): SharedConfig {
  return {
    port: integer("PORT", 8080),
    redisUrl: required("REDIS_URL"),
    streamShards: integer("ANALYTICS_STREAM_SHARDS", 4),
    clickhouse: {
      url: optional("CLICKHOUSE_URL", "http://localhost:8123"),
      user: required("CLICKHOUSE_USER"),
      password: required("CLICKHOUSE_PASSWORD"),
      timeoutMs: integer("CLICKHOUSE_TIMEOUT_MS", 10_000),
      maxResultRows: integer("CLICKHOUSE_MAX_RESULT_ROWS", 100_000),
    },
  };
}

export function loadIngestConfig(): IngestConfig {
  const config: IngestConfig = {
    ...shared(),
    serverToken: token("ANALYTICS_SERVER_TOKEN"),
    readToken: token("ANALYTICS_READ_TOKEN"),
    schemaPath: optional("ANALYTICS_SCHEMA_PATH", DEFAULT_SCHEMA_PATH),
    maxBacklog: integer("ANALYTICS_MAX_BACKLOG", 20_000),
    backlogRefreshMs: integer("ANALYTICS_BACKLOG_REFRESH_MS", 1_000),
    dedupeTtlSeconds: integer("ANALYTICS_DEDUPE_TTL_SECONDS", 3_600),
    retryAfterSeconds: integer("ANALYTICS_RETRY_AFTER_SECONDS", 5),
    requestTimeoutMs: integer("ANALYTICS_REQUEST_TIMEOUT_MS", 15_000),
    eventMaxAgeSeconds: integer("ANALYTICS_EVENT_MAX_AGE_SECONDS", 86_400),
    eventMaxAheadSeconds: integer("ANALYTICS_EVENT_MAX_AHEAD_SECONDS", 300),
    statsMaxMinutes: integer("ANALYTICS_STATS_MAX_MINUTES", 1_440),
  };

  if (config.serverToken === config.readToken) {
    throw new Error("ANALYTICS_SERVER_TOKEN and ANALYTICS_READ_TOKEN must differ, so a reader can never write");
  }

  return config;
}

export function loadWorkerConfig(): WorkerConfig {
  const config: WorkerConfig = {
    ...shared(),
    consumer: optional("ANALYTICS_WORKER_CONSUMER", hostname()),
    readCount: integer("ANALYTICS_WORKER_READ_COUNT", 200),
    blockMs: integer("ANALYTICS_WORKER_BLOCK_MS", 1_000),
    claimIdleMs: integer("ANALYTICS_WORKER_CLAIM_IDLE_MS", 60_000),
    reclaimEveryMs: integer("ANALYTICS_WORKER_RECLAIM_EVERY_MS", 15_000),
    backoffBaseMs: integer("ANALYTICS_WORKER_BACKOFF_BASE_MS", 250),
    backoffMaxMs: integer("ANALYTICS_WORKER_BACKOFF_MAX_MS", 15_000),
    rejectedKept: integer("ANALYTICS_WORKER_REJECTED_KEPT", 10_000),
    staleAfterMs: integer("ANALYTICS_WORKER_STALE_AFTER_MS", 60_000),
    stopGraceMs: integer("ANALYTICS_WORKER_STOP_GRACE_MS", 10_000),
  };

  if ((config.backoffMaxMs + config.clickhouse.timeoutMs) * 2 > config.claimIdleMs) {
    throw new Error(
      "ANALYTICS_WORKER_BACKOFF_MAX_MS plus CLICKHOUSE_TIMEOUT_MS must stay within half of ANALYTICS_WORKER_CLAIM_IDLE_MS, so a retrying worker keeps its entries",
    );
  }

  return config;
}
