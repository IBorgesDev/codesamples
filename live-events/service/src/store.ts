import { createHash } from "node:crypto";
import type { Redis } from "ioredis";
import type { Batch } from "./coalescer.js";
import { CREATE, PUBLISH } from "./scripts.js";

export type EventState = "live" | "completed" | "closed";

export type Goal = { option: string; target: number };

export type EventSpec = {
  options: string[];
  endsAt: number | null;
  goal: Goal | null;
};

export type Tally = Record<string, number>;

export type Contribution = { plus: Tally; minus: Tally };

export type Snapshot = {
  state: EventState;
  version: number;
  totals: Tally;
  completedAt: number | null;
  endsAt: number | null;
  servers: number;
  ignored: number;
};

export type CreateResult = "created" | "exists" | "conflict";

type Runner = (keys: string[], args: (string | number)[]) => Promise<unknown>;

function script(redis: Redis, lua: string): Runner {
  const sha = createHash("sha1").update(lua).digest("hex");
  return async (keys, args) => {
    try {
      return await redis.evalsha(sha, keys.length, ...keys, ...args);
    } catch (error) {
      if (!String(error).includes("NOSCRIPT")) {
        throw error;
      }

      return redis.eval(lua, keys.length, ...keys, ...args);
    }
  };
}

function keys(id: string) {
  const tag = `ev:{${id}}`;
  return {
    meta: `${tag}:meta`,
    options: `${tag}:options`,
    entries: `${tag}:entries`,
    totals: `${tag}:totals`,
    seen: `${tag}:seen`,
  };
}

function tally(flat: unknown): Tally {
  const out: Tally = {};
  const list = Array.isArray(flat) ? flat : [];
  for (let i = 0; i + 1 < list.length; i += 2) {
    out[String(list[i])] = Number(list[i + 1]);
  }

  return out;
}

function optionalNumber(value: unknown): number | null {
  if (value === null || value === undefined || value === "" || Number(value) === 0) {
    return null;
  }

  return Number(value);
}

export class EventStore {
  private readonly runCreate: Runner;
  private readonly runPublish: Runner;

  constructor(
    private readonly redis: Redis,
    private readonly closeGraceSeconds: number,
    private readonly activeWindowSeconds = 30,
  ) {
    this.runCreate = script(redis, CREATE);
    this.runPublish = script(redis, PUBLISH);
  }

  async create(id: string, spec: EventSpec, now: number): Promise<CreateResult> {
    const k = keys(id);
    const encoded = JSON.stringify(spec);
    const existing = await this.runCreate(
      [k.meta, k.options],
      [now, spec.endsAt ?? 0, spec.goal?.option ?? "", spec.goal?.target ?? 0, encoded, ...spec.options],
    );

    if (existing === null) {
      return "created";
    }

    return existing === encoded ? "exists" : "conflict";
  }

  async publish(server: string, events: Record<string, Contribution>, now: number): Promise<Record<string, Snapshot | null>> {
    const batch: Batch = new Map();
    for (const [id, contribution] of Object.entries(events)) {
      batch.set(id, new Map([[server, contribution]]));
    }

    return Object.fromEntries(await this.publishBatch(batch, now));
  }

  async publishBatch(batch: Batch, now: number): Promise<Map<string, Snapshot | null>> {
    const ids = [...batch.keys()];
    const results = await Promise.all(
      ids.map((id) => {
        const servers = batch.get(id) as Map<string, Contribution>;
        const k = keys(id);
        const args: (string | number)[] = [now, this.closeGraceSeconds, this.activeWindowSeconds, servers.size];
        for (const [server, contribution] of servers) {
          const plus = Object.entries(contribution.plus);
          const minus = Object.entries(contribution.minus);
          args.push(server, plus.length + minus.length);
          for (const [option, value] of plus) {
            args.push("p", option, value);
          }

          for (const [option, value] of minus) {
            args.push("m", option, value);
          }
        }

        return this.runPublish([k.meta, k.options, k.entries, k.totals, k.seen], args);
      }),
    );

    return new Map(ids.map((id, index) => [id, this.decode(results[index])]));
  }

  async read(id: string, now: number): Promise<Snapshot | null> {
    return (await this.publish("", { [id]: { plus: {}, minus: {} } }, now))[id] ?? null;
  }

  private decode(raw: unknown): Snapshot | null {
    if (!Array.isArray(raw)) {
      return null;
    }

    const [state, version, completedAt, endsAt, servers, ignored, totals] = raw;
    return {
      state: state as EventState,
      version: Number(version),
      totals: tally(totals),
      completedAt: optionalNumber(completedAt),
      endsAt: optionalNumber(endsAt),
      servers: Number(servers),
      ignored: Number(ignored),
    };
  }
}
