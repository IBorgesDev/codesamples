export type Config = {
  port: number;
  redisUrl: string;
  redisClusterNodes: string[];
  serverToken: string;
  adminToken: string;
  closeGraceSeconds: number;
  maxEventsPerPublish: number;
  maxOptionsPerEvent: number;
  batchMs: number;
  batchMax: number;
  shards: number;
  totalsRefreshMs: number;
};

function required(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`missing environment variable ${name}`);
  }

  return value;
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

export function loadConfig(): Config {
  return {
    port: integer("PORT", 8080),
    redisUrl: required("REDIS_URL"),
    redisClusterNodes: (process.env.REDIS_CLUSTER_NODES ?? "").split(",").filter((node) => node !== ""),
    serverToken: required("EVENTS_SERVER_TOKEN"),
    adminToken: required("EVENTS_ADMIN_TOKEN"),
    closeGraceSeconds: integer("EVENTS_CLOSE_GRACE_SECONDS", 60),
    maxEventsPerPublish: integer("EVENTS_MAX_EVENTS_PER_PUBLISH", 16),
    maxOptionsPerEvent: integer("EVENTS_MAX_OPTIONS_PER_EVENT", 32),
    batchMs: integer("EVENTS_BATCH_MS", 25, 0),
    batchMax: integer("EVENTS_BATCH_MAX", 1000),
    shards: integer("EVENTS_SHARDS", 16),
    totalsRefreshMs: integer("EVENTS_TOTALS_REFRESH_MS", 1000, 0),
  };
}
