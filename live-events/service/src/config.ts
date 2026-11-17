export type RedisNode = { host: string; port: number };

export type Config = {
  port: number;
  redisUrl: string;
  redisPassword: string;
  redisClusterNodes: RedisNode[];
  serverToken: string;
  adminToken: string;
  readToken: string;
  closeGraceSeconds: number;
  activeWindowSeconds: number;
  maxEventsPerPublish: number;
  maxOptionsPerEvent: number;
  bodyLimitBytes: number;
  requestTimeoutMs: number;
  retryAfterSeconds: number;
  batchMs: number;
  batchMaxRequests: number;
  batchMaxFields: number;
  shards: number;
  totalsRefreshMs: number;
};

const MIN_TOKEN_CHARS = 32;
const MAX_SHARDS = 4096;

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

function integer(name: string, fallback: number, minimum = 1, maximum = Number.MAX_SAFE_INTEGER): number {
  const raw = process.env[name];
  if (raw === undefined) {
    return fallback;
  }

  const value = Number(raw);
  if (!Number.isInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be an integer from ${minimum} to ${maximum}`);
  }

  return value;
}

function clusterNodes(raw: string): RedisNode[] {
  return raw
    .split(",")
    .filter((node) => node !== "")
    .map((node) => {
      const [host = "", port = ""] = node.split(":");
      if (host === "" || !Number.isInteger(Number(port))) {
        throw new Error(`REDIS_CLUSTER_NODES entry ${node} must be host:port`);
      }

      return { host, port: Number(port) };
    });
}

export function loadConfig(): Config {
  const redisUrl = required("REDIS_URL");
  const config: Config = {
    port: integer("PORT", 8080),
    redisUrl,
    redisPassword: decodeURIComponent(new URL(redisUrl).password),
    redisClusterNodes: clusterNodes(process.env.REDIS_CLUSTER_NODES ?? ""),
    serverToken: token("EVENTS_SERVER_TOKEN"),
    adminToken: token("EVENTS_ADMIN_TOKEN"),
    readToken: token("EVENTS_READ_TOKEN"),
    closeGraceSeconds: integer("EVENTS_CLOSE_GRACE_SECONDS", 60),
    activeWindowSeconds: integer("EVENTS_ACTIVE_WINDOW_SECONDS", 30),
    maxEventsPerPublish: integer("EVENTS_MAX_EVENTS_PER_PUBLISH", 16),
    maxOptionsPerEvent: integer("EVENTS_MAX_OPTIONS_PER_EVENT", 32),
    bodyLimitBytes: integer("EVENTS_BODY_LIMIT_BYTES", 64 * 1024),
    requestTimeoutMs: integer("EVENTS_REQUEST_TIMEOUT_MS", 15_000),
    retryAfterSeconds: integer("EVENTS_RETRY_AFTER_SECONDS", 5),
    batchMs: integer("EVENTS_BATCH_MS", 25, 0),
    batchMaxRequests: integer("EVENTS_BATCH_MAX", 1000),
    batchMaxFields: integer("EVENTS_BATCH_MAX_FIELDS", 10_000),
    shards: integer("EVENTS_SHARDS", 16, 1, MAX_SHARDS),
    totalsRefreshMs: integer("EVENTS_TOTALS_REFRESH_MS", 1000, 0),
  };

  if (new Set([config.serverToken, config.adminToken, config.readToken]).size < 3) {
    throw new Error("EVENTS_SERVER_TOKEN, EVENTS_ADMIN_TOKEN and EVENTS_READ_TOKEN must all differ, so each role stays separate");
  }

  return config;
}
