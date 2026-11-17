import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { EventRow } from "../src/batch.js";
import { type Catalog, loadCatalog } from "../src/catalog.js";
import type { QueryParams, QueryRunner } from "../src/clickhouse.js";
import type { IngestConfig } from "../src/config.js";
import type { RowSink, ShardEntry, ShardStream } from "../src/pipeline.js";
import type { AppendResult, BatchStore } from "../src/store.js";

export const SCHEMA_DIR = new URL("../../schema/", import.meta.url);

export type FixtureEvent = { valid: boolean; why: string; event: Record<string, unknown> };

export type Fixtures = { envelope: Record<string, unknown>; events: FixtureEvent[] };

export const catalog: Catalog = loadCatalog(fileURLToPath(new URL("events.json", SCHEMA_DIR)));

export const fixtures: Fixtures = JSON.parse(readFileSync(new URL("fixtures.json", SCHEMA_DIR), "utf8"));

export const validFixtures = fixtures.events.filter((fixture) => fixture.valid);

export const invalidFixtures = fixtures.events.filter((fixture) => !fixture.valid);

export function fixtureBatch(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return { ...fixtures.envelope, events: fixtures.events.map((fixture) => fixture.event), ...overrides };
}

export const config: IngestConfig = {
  port: 0,
  redisUrl: "",
  serverToken: "server-token",
  readToken: "read-token",
  schemaPath: "",
  streamShards: 4,
  maxBacklog: 1_000,
  dedupeTtlSeconds: 3_600,
  retryAfterSeconds: 5,
  eventMaxAgeSeconds: 86_400,
  eventMaxAheadSeconds: 300,
  statsMaxMinutes: 1_440,
  clickhouse: { url: "http://clickhouse.invalid", user: "default", password: "", timeoutMs: 1_000 },
};

export class FakeBatchStore implements BatchStore {
  readonly seen = new Set<string>();
  readonly appended: Array<{ serverId: string; batchSeq: number; payload: string }> = [];
  backlogValue = 0;
  backlogReads = 0;
  failing = false;

  async append(serverId: string, batchSeq: number, payload: string): Promise<AppendResult> {
    if (this.failing) {
      throw new Error("redis down");
    }

    const key = `${serverId}:${batchSeq}`;
    if (this.seen.has(key)) {
      return "duplicate";
    }

    this.seen.add(key);
    if (payload !== "") {
      this.appended.push({ serverId, batchSeq, payload });
    }

    return "appended";
  }

  async backlog(): Promise<number> {
    this.backlogReads += 1;
    return this.backlogValue;
  }

  async healthy(): Promise<boolean> {
    return !this.failing;
  }
}

export class FakeQueryRunner implements QueryRunner {
  readonly calls: Array<{ sql: string; params: QueryParams }> = [];
  failing = false;

  constructor(private readonly answer: (sql: string) => unknown[] = () => []) {}

  async query<T>(sql: string, params: QueryParams): Promise<T[]> {
    this.calls.push({ sql, params });
    if (this.failing) {
      throw new Error("clickhouse down");
    }

    return this.answer(sql) as T[];
  }
}

export class FakeShardStream implements ShardStream {
  readonly key = "analytics:events:{0}";
  readonly undelivered: ShardEntry[] = [];
  readonly pending = new Map<string, ShardEntry>();
  readonly orphaned: ShardEntry[] = [];
  readonly acked: string[] = [];
  readonly touched: string[][] = [];
  readonly log: string[];
  failNextRead = false;
  private nextId = 1;

  constructor(log: string[] = []) {
    this.log = log;
  }

  add(batch: string | null): string {
    const id = `${this.nextId++}-0`;
    this.undelivered.push({ id, batch });
    return id;
  }

  orphan(batch: string | null): string {
    const id = `${this.nextId++}-0`;
    this.orphaned.push({ id, batch });
    return id;
  }

  holdPending(batch: string | null): string {
    const id = `${this.nextId++}-0`;
    this.pending.set(id, { id, batch });
    return id;
  }

  async ensureGroup(): Promise<void> {
    this.log.push("ensure");
  }

  async readPending(count: number): Promise<ShardEntry[]> {
    this.log.push("read-pending");
    return [...this.pending.values()].slice(0, count);
  }

  async readNew(count: number): Promise<ShardEntry[]> {
    if (this.failNextRead) {
      this.failNextRead = false;
      throw new Error("connection reset");
    }

    this.log.push("read-new");
    const taken = this.undelivered.splice(0, count);
    for (const entry of taken) {
      this.pending.set(entry.id, entry);
    }

    return taken;
  }

  async reclaim(_minIdleMs: number, count: number): Promise<ShardEntry[]> {
    this.log.push("reclaim");
    const taken = this.orphaned.splice(0, count);
    for (const entry of taken) {
      this.pending.set(entry.id, entry);
    }

    return taken;
  }

  async touch(ids: string[]): Promise<void> {
    this.log.push("touch");
    this.touched.push([...ids]);
  }

  async ack(ids: string[]): Promise<void> {
    this.log.push("ack");
    for (const id of ids) {
      if (this.pending.delete(id)) {
        this.acked.push(id);
      }
    }
  }
}

export class FakeSink implements RowSink {
  readonly inserts: Array<{ rows: EventRow[]; token: string }> = [];
  readonly attempts: string[] = [];
  failuresLeft = 0;
  private readonly log: string[];

  constructor(log: string[] = []) {
    this.log = log;
  }

  async insert(rows: EventRow[], token: string): Promise<void> {
    this.attempts.push(token);
    if (this.failuresLeft > 0) {
      this.failuresLeft -= 1;
      this.log.push("insert-failed");
      throw new Error("clickhouse 503");
    }

    this.log.push("insert");
    this.inserts.push({ rows, token });
  }
}
