import { timingSafeEqual } from "node:crypto";
import Fastify, { type FastifyError, type FastifyInstance, type FastifyReply, type FastifyRequest } from "fastify";
import type { Coalescer } from "./coalescer.js";
import type { Config } from "./config.js";
import { type Log, logger } from "./log.js";
import { ignoredOptions, publishedEvents, registry, requestSeconds } from "./metrics.js";
import { type Contribution, emptyTally, type EventSpec, type EventStore, type RedisClient, type Snapshot } from "./store.js";

const ID = "^[a-z0-9_-]{1,48}$";
const OPTION = "^[a-z0-9_]{1,32}$";
const SERVER = "^[A-Za-z0-9-]{1,64}$";
const BODILESS_ROUTE_BYTES = 1024;
const MILLISECONDS = 1000;

const ERROR_CODES: Record<string, string> = {
  FST_ERR_VALIDATION: "invalid_request",
  FST_ERR_CTP_BODY_TOO_LARGE: "too_large",
  FST_ERR_CTP_INVALID_JSON_BODY: "invalid_json",
  FST_ERR_CTP_EMPTY_JSON_BODY: "invalid_json",
  FST_ERR_CTP_INVALID_MEDIA_TYPE: "unsupported_media_type",
  FST_ERR_CTP_INVALID_CONTENT_LENGTH: "invalid_content_length",
};

type Role = "server" | "admin" | "read";

type Deps = {
  store: EventStore;
  redis: RedisClient;
  config: Config;
  coalescer?: Coalescer;
  now?: () => number;
  log?: Log;
};

type PublishBody = {
  server: string;
  events: Record<string, { plus?: Record<string, number>; minus?: Record<string, number> } | []>;
};

function wire(snapshot: Snapshot) {
  return {
    state: snapshot.state,
    version: snapshot.version,
    totals: snapshot.totals,
    completed_at: snapshot.completedAt,
    ends_at: snapshot.endsAt,
    servers: snapshot.servers,
    ignored: snapshot.ignored,
  };
}

function matches(header: string | undefined, token: string): boolean {
  const presented = Buffer.from(header ?? "");
  const expected = Buffer.from(`Bearer ${token}`);
  return presented.length === expected.length && timingSafeEqual(presented, expected);
}

function contributionFrom(given: PublishBody["events"][string]): Contribution {
  if (Array.isArray(given)) {
    return { plus: emptyTally(), minus: emptyTally() };
  }

  return { plus: Object.assign(emptyTally(), given.plus), minus: Object.assign(emptyTally(), given.minus) };
}

export function buildApp({
  store,
  redis,
  config,
  coalescer,
  now = () => Math.floor(Date.now() / MILLISECONDS),
  log = logger("events"),
}: Deps): FastifyInstance {
  const app = Fastify({
    logger: false,
    bodyLimit: BODILESS_ROUTE_BYTES,
    requestTimeout: config.requestTimeoutMs,
    connectionTimeout: config.requestTimeoutMs,
    ajv: { customOptions: { coerceTypes: false, removeAdditional: false } },
  });
  const tokens: Record<Role, string> = { server: config.serverToken, admin: config.adminToken, read: config.readToken };
  const eventParams = { type: "object", properties: { id: { type: "string", pattern: ID } }, required: ["id"] };
  const tally = {
    type: "object",
    maxProperties: config.maxOptionsPerEvent,
    propertyNames: { pattern: OPTION },
    additionalProperties: { type: "integer", minimum: 0, maximum: Number.MAX_SAFE_INTEGER },
  };

  function guard(...roles: Role[]) {
    return async (request: FastifyRequest, reply: FastifyReply) => {
      if (!roles.some((role) => matches(request.headers.authorization, tokens[role]))) {
        return reply.code(401).send({ error: "unauthorized" });
      }
    };
  }

  app.setErrorHandler((error: FastifyError, _request, reply) => {
    const status = typeof error.statusCode === "number" && error.statusCode >= 400 && error.statusCode < 500 ? error.statusCode : 503;
    if (status === 503) {
      log("request failed", error);
      return reply.code(status).header("retry-after", String(config.retryAfterSeconds)).send({ error: "unavailable" });
    }

    return reply.code(status).send({ error: ERROR_CODES[error.code] ?? "bad_request", detail: error.message });
  });

  app.setNotFoundHandler((_request, reply) => reply.code(404).send({ error: "not_found" }));

  app.addHook("onResponse", async (request, reply) => {
    requestSeconds
      .labels(request.routeOptions.url ?? "unknown", String(reply.statusCode))
      .observe(reply.elapsedTime / MILLISECONDS);
  });

  app.get("/healthz", async (_request, reply) => {
    const pong = await redis.ping().catch(() => null);
    return reply.code(pong === "PONG" ? 200 : 503).send({ redis: pong === "PONG" });
  });

  app.get("/metrics", { onRequest: guard("admin", "read") }, async (_request, reply) => {
    return reply.type(registry.contentType).send(await registry.metrics());
  });

  app.put<{ Params: { id: string }; Body: { options: string[]; ends_at?: number | null; goal?: { option: string; target: number } | null } }>(
    "/v1/events/:id",
    {
      onRequest: guard("admin"),
      bodyLimit: config.bodyLimitBytes,
      schema: {
        params: eventParams,
        body: {
          type: "object",
          additionalProperties: false,
          required: ["options"],
          properties: {
            options: {
              type: "array",
              minItems: 1,
              maxItems: config.maxOptionsPerEvent,
              uniqueItems: true,
              items: { type: "string", pattern: OPTION },
            },
            ends_at: { type: ["integer", "null"], minimum: 0 },
            goal: {
              type: ["object", "null"],
              additionalProperties: false,
              required: ["option", "target"],
              properties: {
                option: { type: "string", pattern: OPTION },
                target: { type: "integer", minimum: 1, maximum: Number.MAX_SAFE_INTEGER },
              },
            },
          },
        },
      },
    },
    async (request, reply) => {
      const { options, ends_at, goal } = request.body;
      if (goal && !options.includes(goal.option)) {
        return reply.code(400).send({ error: "goal_option_unknown" });
      }

      const spec: EventSpec = { options, endsAt: ends_at ?? null, goal: goal ?? null };
      const result = await store.create(request.params.id, spec, now());
      if (result === "conflict") {
        return reply.code(409).send({ error: "event_exists_with_other_spec" });
      }

      return reply.code(result === "created" ? 201 : 200).send({ id: request.params.id, options, ends_at: spec.endsAt, goal: spec.goal });
    },
  );

  app.get<{ Params: { id: string } }>(
    "/v1/events/:id",
    { onRequest: guard("server", "admin", "read"), schema: { params: eventParams } },
    async (request, reply) => {
      const snapshot = await store.read(request.params.id, now());
      if (!snapshot) {
        return reply.code(404).send({ error: "unknown_event" });
      }

      return wire(snapshot);
    },
  );

  app.post<{ Body: PublishBody; Querystring: { sync?: string } }>(
    "/v1/publish",
    {
      onRequest: guard("server"),
      bodyLimit: config.bodyLimitBytes,
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          required: ["server", "events"],
          properties: {
            server: { type: "string", pattern: SERVER },
            events: {
              type: "object",
              minProperties: 1,
              maxProperties: config.maxEventsPerPublish,
              propertyNames: { pattern: ID },
              additionalProperties: {
                anyOf: [
                  { type: "object", additionalProperties: false, properties: { plus: tally, minus: tally } },
                  { type: "array", maxItems: 0 },
                ],
              },
            },
          },
        },
      },
    },
    async (request) => {
      const events: Record<string, Contribution> = {};
      for (const [id, given] of Object.entries(request.body.events)) {
        events[id] = contributionFrom(given);
      }

      const coalesced = coalescer !== undefined && request.query.sync !== "1";
      const snapshots = coalesced ? await coalescer.add(request.body.server, events) : await store.publish(request.body.server, events, now());
      const wired: Record<string, ReturnType<typeof wire>> = {};
      const missing: string[] = [];
      for (const id of Object.keys(events)) {
        const snapshot = snapshots.get(id);
        if (snapshot) {
          wired[id] = wire(snapshot);
          publishedEvents.labels(snapshot.state).inc();
          if (!coalesced) {
            ignoredOptions.inc(snapshot.ignored);
          }
        } else {
          missing.push(id);
        }
      }

      publishedEvents.labels("missing").inc(missing.length);

      return { events: wired, missing };
    },
  );

  return app;
}
