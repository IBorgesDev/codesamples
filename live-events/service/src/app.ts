import { timingSafeEqual } from "node:crypto";
import Fastify, { type FastifyInstance, type FastifyReply, type FastifyRequest } from "fastify";
import type { Redis } from "ioredis";
import type { Config } from "./config.js";
import { ignoredOptions, publishedEvents, registry, requestSeconds } from "./metrics.js";
import type { Coalescer } from "./coalescer.js";
import type { Contribution, EventSpec, EventStore, Snapshot } from "./store.js";

const ID = "^[a-z0-9_-]{1,48}$";
const OPTION = "^[a-z0-9_]{1,32}$";
const SERVER = "^[A-Za-z0-9-]{1,64}$";

type Role = "server" | "admin";

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

type Deps = {
  store: EventStore;
  redis: Redis;
  config: Config;
  coalescer?: Coalescer;
  now?: () => number;
};

function matches(header: string | undefined, token: string): boolean {
  const presented = Buffer.from(header ?? "");
  const expected = Buffer.from(`Bearer ${token}`);
  return presented.length === expected.length && timingSafeEqual(presented, expected);
}

export function buildApp({ store, redis, config, coalescer, now = () => Math.floor(Date.now() / 1000) }: Deps): FastifyInstance {
  const app = Fastify({ logger: false, bodyLimit: 64 * 1024 });

  const tally = {
    type: "object",
    maxProperties: config.maxOptionsPerEvent,
    propertyNames: { pattern: OPTION },
    additionalProperties: { type: "integer", minimum: 0, maximum: Number.MAX_SAFE_INTEGER },
  };

  function guard(...roles: Role[]) {
    return async (request: FastifyRequest, reply: FastifyReply) => {
      const header = request.headers.authorization;
      const allowed =
        (roles.includes("server") && matches(header, config.serverToken)) ||
        (roles.includes("admin") && matches(header, config.adminToken));

      if (!allowed) {
        await reply.code(401).send({ error: "unauthorized" });
      }
    };
  }

  app.addHook("onResponse", async (request, reply) => {
    requestSeconds
      .labels(request.routeOptions.url ?? "unknown", String(reply.statusCode))
      .observe(reply.elapsedTime / 1000);
  });

  app.get("/healthz", async (_request, reply) => {
    const pong = await redis.ping().catch(() => null);
    return reply.code(pong === "PONG" ? 200 : 503).send({ redis: pong === "PONG" });
  });

  app.get("/metrics", async (_request, reply) => {
    return reply.type(registry.contentType).send(await registry.metrics());
  });

  app.put<{ Params: { id: string }; Body: { options: string[]; ends_at?: number | null; goal?: { option: string; target: number } | null } }>(
    "/v1/events/:id",
    {
      preHandler: guard("admin"),
      schema: {
        params: { type: "object", properties: { id: { type: "string", pattern: ID } }, required: ["id"] },
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
                target: { type: "integer", minimum: 1 },
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
    {
      preHandler: guard("server", "admin"),
      schema: { params: { type: "object", properties: { id: { type: "string", pattern: ID } }, required: ["id"] } },
    },
    async (request, reply) => {
      const snapshot = await store.read(request.params.id, now());
      if (!snapshot) {
        return reply.code(404).send({ error: "unknown_event" });
      }

      return wire(snapshot);
    },
  );

  app.post<{
    Body: { server: string; events: Record<string, { plus?: Record<string, number>; minus?: Record<string, number> }> };
    Querystring: { sync?: string };
  }>(
    "/v1/publish",
    {
      preHandler: guard("server"),
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
                type: "object",
                additionalProperties: false,
                properties: { plus: tally, minus: tally },
              },
            },
          },
        },
      },
    },
    async (request) => {
      const events: Record<string, Contribution> = {};
      for (const [id, contribution] of Object.entries(request.body.events)) {
        events[id] = { plus: contribution.plus ?? {}, minus: contribution.minus ?? {} };
      }

      const sync = request.query.sync === "1" || !coalescer;
      const all = sync
        ? new Map(Object.entries(await store.publish(request.body.server, events, now())))
        : await (coalescer as Coalescer).add(request.body.server, events);
      const snapshots: Record<string, Snapshot | null> = {};
      for (const id of Object.keys(events)) {
        snapshots[id] = all.get(id) ?? null;
      }

      const missing = Object.keys(snapshots).filter((id) => snapshots[id] === null);
      for (const snapshot of Object.values(snapshots)) {
        if (snapshot) {
          publishedEvents.labels(snapshot.state).inc();
          ignoredOptions.inc(snapshot.ignored);
        }
      }

      publishedEvents.labels("missing").inc(missing.length);
      const wired: Record<string, ReturnType<typeof wire>> = {};
      for (const [id, snapshot] of Object.entries(snapshots)) {
        if (snapshot) {
          wired[id] = wire(snapshot);
        }
      }

      return { events: wired, missing };
    },
  );

  return app;
}
