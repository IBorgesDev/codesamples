import { timingSafeEqual } from "node:crypto";
import { createGunzip, type Gunzip } from "node:zlib";
import Fastify, { type FastifyError, type FastifyInstance, type FastifyReply, type FastifyRequest, type RequestPayload } from "fastify";
import { BacklogMonitor } from "./backlog.js";
import { encodeBatch } from "./batch.js";
import type { Catalog } from "./catalog.js";
import type { IngestConfig } from "./config.js";
import { type Log, logger } from "./log.js";
import type { IngestMetrics } from "./metrics.js";
import { isRecord } from "./record.js";
import type { StatsSource } from "./stats.js";
import type { AppendResult, BatchStore } from "./store.js";
import { checkWindow, type Envelope, type EventRejection, parseEnvelope, type TrackedEvent, validateEvent } from "./validate.js";

export type IngestDeps = {
  config: IngestConfig;
  catalog: Catalog;
  store: BatchStore;
  stats: StatsSource;
  metrics: IngestMetrics;
  now?: () => number;
  log?: Log;
};

type Decoded = Gunzip & { receivedEncodedLength?: number };

type Sifted = { accepted: TrackedEvent[]; rejected: Map<EventRejection, number> };

const BATCH_ROUTE = "/v1/batch";
const BODILESS_ROUTE_BYTES = 1024;
const UNSUPPORTED_ENCODING = "UNSUPPORTED_ENCODING";
const DEFAULT_MINUTES = 60;
const MILLISECONDS = 1000;

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
  const raw = isRecord(query) ? query.minutes : undefined;
  const value = Number.parseInt(String(raw ?? DEFAULT_MINUTES), 10);
  if (!Number.isFinite(value)) {
    return Math.min(DEFAULT_MINUTES, maximum);
  }

  return Math.min(Math.max(value, 1), maximum);
}

export function buildApp({ config, catalog, store, stats, metrics, now = Date.now, log = logger("analytics") }: IngestDeps): FastifyInstance {
  const app = Fastify({
    logger: false,
    bodyLimit: BODILESS_ROUTE_BYTES,
    requestTimeout: config.requestTimeoutMs,
    connectionTimeout: config.requestTimeoutMs,
  });
  const backlog = new BacklogMonitor(
    () => store.backlog(),
    (value) => metrics.backlog.set(value),
    config.backlogRefreshMs,
    now,
  );
  const window = { maxAgeSeconds: config.eventMaxAgeSeconds, maxAheadSeconds: config.eventMaxAheadSeconds };

  function guard(token: string) {
    return async (request: FastifyRequest, reply: FastifyReply) => {
      if (matches(request.headers.authorization, token)) {
        return;
      }

      if (request.routeOptions.url === BATCH_ROUTE) {
        metrics.batches.labels("unauthorized").inc();
      }

      return reply.code(401).send({ error: "unauthorized" });
    };
  }

  function unavailable(reply: FastifyReply, reason: string) {
    metrics.batches.labels(reason).inc();
    return reply.code(503).header("retry-after", String(config.retryAfterSeconds)).send({ error: reason });
  }

  async function shedWhenBehind(_request: FastifyRequest, reply: FastifyReply) {
    if ((await backlog.current()) > config.maxBacklog) {
      return unavailable(reply, "backpressure");
    }
  }

  function sift(events: unknown[], receivedAt: number): Sifted {
    const accepted: TrackedEvent[] = [];
    const rejected = new Map<EventRejection, number>();
    for (const raw of events) {
      const result = validateEvent(raw, catalog);
      const problem = result.ok ? checkWindow(result.event.at, receivedAt, window) : result.reason;
      if (result.ok && problem === null) {
        accepted.push(result.event);
      } else if (problem !== null) {
        rejected.set(problem, (rejected.get(problem) ?? 0) + 1);
      }
    }

    return { accepted, rejected };
  }

  function recordStored(envelope: Envelope, { accepted, rejected }: Sifted) {
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
  }

  function statsRoute<T extends object>(path: string, read: (minutes: number) => Promise<T>) {
    app.get(path, { onRequest: guard(config.readToken) }, async (request, reply) => {
      const minutes = minutesFrom(request.query, config.statsMaxMinutes);
      try {
        return { minutes, ...(await read(minutes)) };
      } catch (error) {
        log("stats query failed", error);
        return reply.code(503).header("retry-after", String(config.retryAfterSeconds)).send({ error: "stats_unavailable" });
      }
    });
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

  app.setNotFoundHandler((_request, reply) => reply.code(404).send({ error: "not_found" }));

  app.addHook("onResponse", async (request, reply) => {
    if (request.routeOptions.url === BATCH_ROUTE) {
      metrics.ingestSeconds.labels(String(reply.statusCode)).observe(reply.elapsedTime / MILLISECONDS);
    }
  });

  app.get("/healthz", async (_request, reply) => {
    const redis = await store.healthy();
    return reply.code(redis ? 200 : 503).send({ redis });
  });

  app.get("/metrics", { onRequest: guard(config.readToken) }, async (_request, reply) => {
    return reply.type(metrics.registry.contentType).send(await metrics.registry.metrics());
  });

  app.post(
    BATCH_ROUTE,
    { bodyLimit: catalog.limits.batchBytes, onRequest: [guard(config.serverToken), shedWhenBehind], preParsing: decompress },
    async (request, reply) => {
      const parsed = parseEnvelope(request.body, catalog);
      if (!parsed.ok) {
        metrics.batches.labels("invalid").inc();
        return reply.code(400).send({ error: parsed.reason });
      }

      const { envelope } = parsed;
      const receivedAt = now() / MILLISECONDS;
      const sifted = sift(envelope.events, receivedAt);
      const payload = sifted.accepted.length > 0 ? encodeBatch(envelope, receivedAt, sifted.accepted) : "";
      let result: AppendResult;
      try {
        result = await store.append(envelope.server_id, envelope.batch_seq, payload);
      } catch (error) {
        log("append failed", error);
        return unavailable(reply, "unavailable");
      }

      const counts = { accepted: sifted.accepted.length, rejected: envelope.events.length - sifted.accepted.length };
      if (result === "duplicate") {
        metrics.batches.labels("duplicate").inc();
        metrics.duplicates.inc();
        return { ...counts, duplicate: true };
      }

      recordStored(envelope, sifted);
      return { ...counts, duplicate: false };
    },
  );

  statsRoute("/v1/stats/overview", (minutes) => stats.overview(minutes));
  statsRoute("/v1/stats/trades", (minutes) => stats.trades(minutes));

  return app;
}
