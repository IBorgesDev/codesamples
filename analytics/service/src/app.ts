import { timingSafeEqual } from "node:crypto";
import { createGunzip, type Gunzip } from "node:zlib";
import Fastify, { type FastifyError, type FastifyInstance, type FastifyReply, type FastifyRequest, type RequestPayload } from "fastify";
import { BacklogMonitor } from "./backlog.js";
import type { StoredBatch } from "./batch.js";
import type { Catalog } from "./catalog.js";
import type { IngestConfig } from "./config.js";
import type { IngestMetrics } from "./metrics.js";
import type { StatsSource } from "./stats.js";
import type { AppendResult, BatchStore } from "./store.js";
import { checkWindow, type EventRejection, parseEnvelope, type TrackedEvent, validateEvent } from "./validate.js";

export type IngestDeps = {
  config: IngestConfig;
  catalog: Catalog;
  store: BatchStore;
  stats: StatsSource;
  metrics: IngestMetrics;
  now?: () => number;
  backlogIntervalMs?: number;
  log?: (message: string, error: unknown) => void;
};

type Decoded = Gunzip & { receivedEncodedLength?: number };

const BATCH_ROUTE = "/v1/batch";
const UNSUPPORTED_ENCODING = "UNSUPPORTED_ENCODING";
const DEFAULT_MINUTES = 60;

const ERROR_CODES: Record<string, string> = {
  FST_ERR_CTP_BODY_TOO_LARGE: "too_large",
  FST_ERR_CTP_INVALID_JSON_BODY: "invalid_json",
  FST_ERR_CTP_EMPTY_JSON_BODY: "invalid_json",
  FST_ERR_CTP_INVALID_MEDIA_TYPE: "unsupported_media_type",
  FST_ERR_CTP_INVALID_CONTENT_LENGTH: "invalid_content_length",
  [UNSUPPORTED_ENCODING]: "unsupported_encoding",
};

function matches(header: string | undefined, token: string): boolean {
  const presented = Buffer.from(header ?? "");
  const expected = Buffer.from(`Bearer ${token}`);
  return presented.length === expected.length && timingSafeEqual(presented, expected);
}

function errorCode(error: FastifyError, status: number): string {
  const known = ERROR_CODES[error.code];
  if (known !== undefined) {
    return known;
  }

  if (typeof error.code === "string" && error.code.startsWith("Z_")) {
    return "invalid_gzip";
  }

  return status >= 500 ? "internal" : "bad_request";
}

function unsupportedEncoding(encoding: string): Error {
  return Object.assign(new Error(`unsupported content-encoding ${encoding}`), { statusCode: 415, code: UNSUPPORTED_ENCODING });
}

async function decompress(request: FastifyRequest, _reply: FastifyReply, payload: RequestPayload): Promise<RequestPayload> {
  const encoding = String(request.headers["content-encoding"] ?? "identity").trim().toLowerCase();
  if (encoding === "identity" || encoding === "") {
    return payload;
  }

  if (encoding !== "gzip" && encoding !== "x-gzip") {
    throw unsupportedEncoding(encoding);
  }

  const gunzip: Decoded = createGunzip();
  let encoded = 0;
  payload.on("data", (chunk: Buffer) => {
    encoded += chunk.length;
    gunzip.receivedEncodedLength = encoded;
  });
  payload.on("error", (error) => gunzip.destroy(error));
  gunzip.on("error", (error: Error & { statusCode?: number }) => {
    error.statusCode = 400;
  });
  payload.pipe(gunzip);
  return gunzip;
}

function minutesFrom(query: unknown, maximum: number): number {
  const raw = (query as { minutes?: unknown } | undefined)?.minutes;
  const value = Number.parseInt(String(raw ?? DEFAULT_MINUTES), 10);
  if (!Number.isFinite(value)) {
    return Math.min(DEFAULT_MINUTES, maximum);
  }

  return Math.min(Math.max(value, 1), maximum);
}

export function buildApp({
  config,
  catalog,
  store,
  stats,
  metrics,
  now = Date.now,
  backlogIntervalMs = 1000,
  log = (message, error) => console.error(`analytics: ${message}`, error),
}: IngestDeps): FastifyInstance {
  const app = Fastify({ logger: false });
  const backlog = new BacklogMonitor(
    () => store.backlog(),
    (value) => metrics.backlog.set(value),
    backlogIntervalMs,
    now,
  );

  function guard(token: string) {
    return async (request: FastifyRequest, reply: FastifyReply) => {
      if (!matches(request.headers.authorization, token)) {
        if (request.routeOptions.url === BATCH_ROUTE) {
          metrics.batches.labels("unauthorized").inc();
        }

        await reply.code(401).send({ error: "unauthorized" });
      }
    };
  }

  function unavailable(reply: FastifyReply, reason: string) {
    metrics.batches.labels(reason).inc();
    return reply.code(503).header("retry-after", String(config.retryAfterSeconds)).send({ error: reason });
  }

  app.setErrorHandler((error: FastifyError, request, reply) => {
    const status = typeof error.statusCode === "number" && error.statusCode >= 400 && error.statusCode < 600 ? error.statusCode : 500;
    const code = errorCode(error, status);
    if (request.routeOptions.url === BATCH_ROUTE) {
      metrics.batches.labels(code).inc();
    }

    if (status >= 500) {
      log("request failed", error);
    }

    return reply.code(status).send({ error: code });
  });

  app.addHook("onResponse", async (request, reply) => {
    if (request.routeOptions.url === BATCH_ROUTE) {
      metrics.ingestSeconds.labels(String(reply.statusCode)).observe(reply.elapsedTime / 1000);
    }
  });

  app.get("/healthz", async (_request, reply) => {
    const redis = await store.healthy();
    return reply.code(redis ? 200 : 503).send({ redis });
  });

  app.get("/metrics", async (_request, reply) => {
    return reply.type(metrics.registry.contentType).send(await metrics.registry.metrics());
  });

  app.post(
    BATCH_ROUTE,
    { bodyLimit: catalog.limits.batchBytes, onRequest: guard(config.serverToken), preParsing: decompress },
    async (request, reply) => {
      const parsed = parseEnvelope(request.body, catalog);
      if (!parsed.ok) {
        metrics.batches.labels("invalid").inc();
        return reply.code(400).send({ error: parsed.reason });
      }

      if ((await backlog.current()) > config.maxBacklog) {
        return unavailable(reply, "backpressure");
      }

      const { envelope } = parsed;
      const receivedAt = now() / 1000;
      const window = { maxAgeSeconds: config.eventMaxAgeSeconds, maxAheadSeconds: config.eventMaxAheadSeconds };
      const accepted: TrackedEvent[] = [];
      const rejected = new Map<EventRejection, number>();
      for (const raw of envelope.events) {
        const result = validateEvent(raw, catalog);
        const reason = result.ok ? checkWindow(result.event.at, receivedAt, window) : result.reason;
        if (reason !== null) {
          rejected.set(reason, (rejected.get(reason) ?? 0) + 1);
        } else if (result.ok) {
          accepted.push(result.event);
        }
      }

      const batch: StoredBatch = { ...envelope, received_at: receivedAt, events: accepted };
      let result: AppendResult;
      try {
        result = await store.append(envelope.server_id, envelope.batch_seq, accepted.length > 0 ? JSON.stringify(batch) : "");
      } catch (error) {
        log("append failed", error);
        return unavailable(reply, "unavailable");
      }

      const rejectedCount = envelope.events.length - accepted.length;
      if (result === "duplicate") {
        metrics.batches.labels("duplicate").inc();
        metrics.duplicates.inc();
        return { accepted: accepted.length, rejected: rejectedCount, duplicate: true };
      }

      metrics.batches.labels("stored").inc();
      metrics.clientDropped.inc(envelope.dropped);
      const perName = new Map<string, number>();
      for (const event of accepted) {
        perName.set(event.name, (perName.get(event.name) ?? 0) + 1);
      }

      for (const [name, count] of perName) {
        metrics.accepted.labels(name).inc(count);
      }

      for (const [reason, count] of rejected) {
        metrics.rejected.labels(reason).inc(count);
      }

      return { accepted: accepted.length, rejected: rejectedCount, duplicate: false };
    },
  );

  async function answerStats<T extends object>(reply: FastifyReply, minutes: number, read: () => Promise<T>) {
    try {
      return { minutes, ...(await read()) };
    } catch (error) {
      log("stats query failed", error);
      return reply.code(503).header("retry-after", String(config.retryAfterSeconds)).send({ error: "stats_unavailable" });
    }
  }

  app.get("/v1/stats/overview", { onRequest: guard(config.readToken) }, async (request, reply) => {
    const minutes = minutesFrom(request.query, config.statsMaxMinutes);
    return answerStats(reply, minutes, () => stats.overview(minutes));
  });

  app.get("/v1/stats/trades", { onRequest: guard(config.readToken) }, async (request, reply) => {
    const minutes = minutesFrom(request.query, config.statsMaxMinutes);
    return answerStats(reply, minutes, () => stats.trades(minutes));
  });

  return app;
}
