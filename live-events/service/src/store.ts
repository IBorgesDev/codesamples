import { createHash } from "node:crypto";
import type { Cluster, Redis } from "ioredis";
import type { Batch } from "./coalescer.js";
import { COMPLETE, CREATE, PUBLISH_SHARD, READ_SHARD, VIEW } from "./scripts.js";

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

export type RedisClient = Redis | Cluster;

export type StoreOptions = {
  closeGraceSeconds: number;
  shards: number;
  refreshMs: number;
  activeWindowSeconds?: number;
  clock?: () => number;
};

type Runner = (keys: string[], args: (string | number)[]) => Promise<unknown>;

type View = {
  state: "live" | "completed";
  endsAt: number | null;
  goal: Goal | null;
  completedAt: number | null;
  shards: number;
  options: string[];
  at: number;
};

type ShardResult = { version: number; active: number; ignored: number; totals: Tally; at: number };

const FNV_OFFSET = 0x811c9dc5;
const FNV_PRIME = 0x01000193;

function script(redis: RedisClient, lua: string): Runner {
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

export function shardOf(server: string, shards: number): number {
  let hash = FNV_OFFSET;
  for (const byte of Buffer.from(server, "utf8")) {
    hash = Math.imul(hash ^ byte, FNV_PRIME);
  }

  return (hash >>> 0) % shards;
}

function eventKeys(id: string) {
  const tag = `ev:{${id}}`;
  return { meta: `${tag}:meta`, options: `${tag}:options` };
}

export function shardKeys(id: string, shard: number): string[] {
  const tag = `ev:{${id}:${shard}}`;
  return [`${tag}:entries`, `${tag}:totals`, `${tag}:seen`, `${tag}:version`];
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

function shardResult(raw: unknown, at: number): ShardResult {
  const [version, active, ignored, totals] = Array.isArray(raw) ? raw : [];
  return { version: Number(version ?? 0), active: Number(active ?? 0), ignored: Number(ignored ?? 0), totals: tally(totals), at };
}

export class EventStore {
  private readonly runCreate: Runner;
  private readonly runView: Runner;
  private readonly runComplete: Runner;
  private readonly runPublish: Runner;
  private readonly runRead: Runner;
  private readonly views = new Map<string, View>();
  private readonly shardCache = new Map<string, ShardResult[]>();
  private readonly closeGraceSeconds: number;
  private readonly shards: number;
  private readonly refreshMs: number;
  private readonly activeWindowSeconds: number;
  private readonly clock: () => number;

  constructor(redis: RedisClient, options: StoreOptions) {
    this.runCreate = script(redis, CREATE);
    this.runView = script(redis, VIEW);
    this.runComplete = script(redis, COMPLETE);
    this.runPublish = script(redis, PUBLISH_SHARD);
    this.runRead = script(redis, READ_SHARD);
    this.closeGraceSeconds = options.closeGraceSeconds;
    this.shards = options.shards;
    this.refreshMs = options.refreshMs;
    this.activeWindowSeconds = options.activeWindowSeconds ?? 30;
    this.clock = options.clock ?? Date.now;
  }

  async create(id: string, spec: EventSpec, now: number): Promise<CreateResult> {
    const k = eventKeys(id);
    const encoded = JSON.stringify(spec);
    const existing = await this.runCreate(
      [k.meta, k.options],
      [now, spec.endsAt ?? 0, spec.goal?.option ?? "", spec.goal?.target ?? 0, encoded, this.shards, ...spec.options],
    );

    this.views.delete(id);
    this.shardCache.delete(id);
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
    const snapshots = await Promise.all(ids.map((id) => this.publishEvent(id, batch.get(id) as Map<string, Contribution>, now, false)));
    return new Map(ids.map((id, index) => [id, snapshots[index] ?? null]));
  }

  async read(id: string, now: number): Promise<Snapshot | null> {
    return this.publishEvent(id, new Map(), now, true);
  }

  private async view(id: string, fresh: boolean): Promise<View | null> {
    const cached = this.views.get(id);
    if (cached && !fresh && this.clock() - cached.at < this.refreshMs) {
      return cached;
    }

    const k = eventKeys(id);
    const raw = await this.runView([k.meta, k.options], []);
    if (!Array.isArray(raw)) {
      this.views.delete(id);
      return null;
    }

    const [state, endsAt, goalOption, goalTarget, completedAt, shards, options] = raw;
    const view: View = {
      state: state === "completed" ? "completed" : "live",
      endsAt: optionalNumber(endsAt),
      goal: goalOption ? { option: String(goalOption), target: Number(goalTarget) } : null,
      completedAt: optionalNumber(completedAt),
      shards: Math.max(1, Number(shards) || 1),
      options: Array.isArray(options) ? options.map(String) : [],
      at: this.clock(),
    };
    this.views.set(id, view);
    return view;
  }

  private async publishEvent(id: string, servers: Map<string, Contribution>, now: number, fresh: boolean): Promise<Snapshot | null> {
    const view = await this.view(id, fresh);
    if (!view) {
      return null;
    }

    const closed = view.endsAt !== null && now >= view.endsAt + this.closeGraceSeconds;
    const byShard = new Map<number, Map<string, Contribution>>();
    for (const [server, contribution] of servers) {
      const shard = shardOf(server, view.shards);
      const group = byShard.get(shard) ?? new Map<string, Contribution>();
      group.set(server, contribution);
      byShard.set(shard, group);
    }

    let cache = this.shardCache.get(id);
    if (!cache) {
      cache = [];
      this.shardCache.set(id, cache);
    }

    const at = this.clock();
    const results = await Promise.all(
      Array.from({ length: view.shards }, async (_, shard) => {
        const group = byShard.get(shard);
        if (group) {
          const raw = await this.runPublish(shardKeys(id, shard), this.publishArgs(view, group, now, closed));
          return shardResult(raw, at);
        }

        const known = cache[shard];
        if (known && !fresh && at - known.at < this.refreshMs) {
          return { ...known, ignored: 0 };
        }

        return shardResult(await this.runRead(shardKeys(id, shard), [now, this.activeWindowSeconds]), at);
      }),
    );

    const totals: Tally = {};
    let version = 0;
    let active = 0;
    let ignored = 0;
    results.forEach((result, shard) => {
      cache[shard] = result;
      version += result.version;
      active += result.active;
      ignored += result.ignored;
      for (const [option, value] of Object.entries(result.totals)) {
        totals[option] = (totals[option] ?? 0) + value;
      }
    });

    if (!closed && view.state === "live" && view.goal && (totals[view.goal.option] ?? 0) >= view.goal.target) {
      const [state, completedAt] = (await this.runComplete([eventKeys(id).meta], [now])) as [string, string];
      if (state === "completed") {
        view.state = "completed";
        view.completedAt = optionalNumber(completedAt);
      }
    }

    return {
      state: closed ? "closed" : view.state,
      version,
      totals,
      completedAt: view.completedAt,
      endsAt: view.endsAt,
      servers: active,
      ignored,
    };
  }

  private publishArgs(view: View, servers: Map<string, Contribution>, now: number, closed: boolean): (string | number)[] {
    const args: (string | number)[] = [now, this.activeWindowSeconds, closed ? 1 : 0, view.options.length, ...view.options, servers.size];
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

    return args;
  }
}
