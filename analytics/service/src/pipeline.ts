import { createHash } from "node:crypto";
import { setTimeout as delay } from "node:timers/promises";
import { decodeBatch, type EventRow, toRows } from "./batch.js";
import type { InsertResult } from "./clickhouse.js";
import { type Log, logger } from "./log.js";
import type { WorkerMetrics } from "./metrics.js";
import { isMissingGroup, type StreamEntry } from "./redis.js";

export interface ShardStream {
  readonly key: string;
  ensureGroup(): Promise<void>;
  readPending(count: number): Promise<StreamEntry[]>;
  readNew(count: number, blockMs: number): Promise<StreamEntry[]>;
  reclaim(minIdleMs: number, count: number): Promise<StreamEntry[]>;
  touch(ids: string[]): Promise<void>;
  ack(ids: string[]): Promise<void>;
  setAside(entry: StreamEntry): Promise<void>;
  trim(): Promise<void>;
}

export interface RowSink {
  insert(rows: EventRow[], token: string): Promise<InsertResult>;
}

export type Sleep = (ms: number, signal?: AbortSignal) => Promise<void>;

export type ShardWorkerOptions = {
  readCount: number;
  blockMs: number;
  claimIdleMs: number;
  reclaimEveryMs: number;
  backoffBaseMs: number;
  backoffMaxMs: number;
  now?: () => number;
  sleep?: Sleep;
  random?: () => number;
  log?: Log;
};

type Load = { entry: StreamEntry; rows: EventRow[] };

class Stopped extends Error {
  constructor() {
    super("worker stopped");
  }
}

const sleepUnlessStopped: Sleep = async (ms, signal) => {
  try {
    await delay(ms, undefined, { signal });
  } catch {
    return;
  }
};

function dedupToken(streamKey: string, ids: string[]): string {
  return `${streamKey}:${ids.length}:${createHash("sha256").update(ids.join(",")).digest("hex")}`;
}

function fullJitter(attempt: number, baseMs: number, maxMs: number, random: () => number): number {
  return random() * Math.min(maxMs, baseMs * 2 ** attempt);
}

export class ShardWorker {
  private drainingOwnPending = true;
  private lastReclaimAt = Number.NEGATIVE_INFINITY;
  private beatAt: number;
  private readonly now: () => number;
  private readonly sleep: Sleep;
  private readonly random: () => number;
  private readonly log: Log;

  constructor(
    private readonly stream: ShardStream,
    private readonly sink: RowSink,
    private readonly metrics: WorkerMetrics,
    private readonly options: ShardWorkerOptions,
  ) {
    this.now = options.now ?? Date.now;
    this.sleep = options.sleep ?? sleepUnlessStopped;
    this.random = options.random ?? Math.random;
    this.log = options.log ?? logger("analytics-worker");
    this.beatAt = this.now();
  }

  lastBeatAt(): number {
    return this.beatAt;
  }

  async run(signal: AbortSignal): Promise<void> {
    let failures = 0;
    let groupReady = false;
    while (!signal.aborted) {
      try {
        if (!groupReady) {
          await this.stream.ensureGroup();
          groupReady = true;
        }

        await this.step(signal);
        failures = 0;
      } catch (error) {
        if (signal.aborted || error instanceof Stopped) {
          break;
        }

        if (isMissingGroup(error)) {
          groupReady = false;
        }

        this.drainingOwnPending = true;
        this.metrics.failures.labels("read").inc();
        this.log(`${this.stream.key} step failed`, error);
        await this.sleep(this.backoff(failures), signal);
        failures += 1;
      }

      this.beatAt = this.now();
    }
  }

  async step(signal?: AbortSignal): Promise<void> {
    const { entries, reclaimed } = await this.nextEntries();
    if (entries.length === 0) {
      return;
    }

    if (reclaimed) {
      this.metrics.reclaimed.inc(entries.length);
    }

    await this.deliver(entries, signal);
  }

  private async nextEntries(): Promise<{ entries: StreamEntry[]; reclaimed: boolean }> {
    if (this.drainingOwnPending) {
      const entries = await this.stream.readPending(this.options.readCount);
      this.drainingOwnPending = entries.length > 0;
      return { entries, reclaimed: false };
    }

    if (this.now() - this.lastReclaimAt >= this.options.reclaimEveryMs) {
      this.lastReclaimAt = this.now();
      const entries = await this.stream.reclaim(this.options.claimIdleMs, this.options.readCount);
      if (entries.length > 0) {
        return { entries, reclaimed: true };
      }
    }

    return { entries: await this.stream.readNew(this.options.readCount, this.options.blockMs), reclaimed: false };
  }

  private async deliver(entries: StreamEntry[], signal?: AbortSignal): Promise<void> {
    const ids = entries.map((entry) => entry.id);
    const loads = this.decode(entries);
    if (loads.length > 0 && (await this.insert(loads, ids, ids, signal)) === "rejected") {
      await this.isolateRejected(loads, ids, signal);
    }

    await this.retry("ack", ids, signal, () => this.stream.ack(ids));
    this.metrics.entries.inc(ids.length);
    await this.stream.trim().catch((error: unknown) => this.log(`${this.stream.key} trim failed`, error));
  }

  private decode(entries: StreamEntry[]): Load[] {
    const loads: Load[] = [];
    for (const entry of entries) {
      const batch = decodeBatch(entry.batch);
      if (batch === null) {
        this.metrics.malformed.inc();
      } else if (batch.events.length > 0) {
        loads.push({ entry, rows: toRows(batch) });
      }
    }

    return loads;
  }

  private async insert(loads: Load[], tokenIds: string[], heldIds: string[], signal?: AbortSignal): Promise<InsertResult> {
    const rows = loads.flatMap((load) => load.rows);
    const token = dedupToken(this.stream.key, tokenIds);
    const result = await this.retry("insert", heldIds, signal, async () => {
      const stopTimer = this.metrics.insertSeconds.startTimer();
      const outcome = await this.sink.insert(rows, token);
      stopTimer();
      return outcome;
    });

    if (result === "stored") {
      this.metrics.rows.inc(rows.length);
    }

    return result;
  }

  private async isolateRejected(loads: Load[], heldIds: string[], signal?: AbortSignal): Promise<void> {
    for (const load of loads) {
      const alone = loads.length === 1;
      if (alone || (await this.insert([load], [load.entry.id], heldIds, signal)) === "rejected") {
        await this.retry("set_aside", heldIds, signal, () => this.stream.setAside(load.entry));
        this.metrics.rejected.inc();
        this.log(`${this.stream.key} set aside entry ${load.entry.id}`, "the database refused its rows");
      }
    }
  }

  private async retry<T>(stage: string, heldIds: string[], signal: AbortSignal | undefined, action: () => Promise<T>): Promise<T> {
    for (let attempt = 0; ; attempt++) {
      try {
        return await action();
      } catch (error) {
        this.metrics.failures.labels(stage).inc();
        this.log(`${this.stream.key} ${stage} failed (attempt ${attempt + 1})`, error);
        if (signal?.aborted) {
          throw new Stopped();
        }

        await this.sleep(this.backoff(attempt), signal);
        if (signal?.aborted) {
          throw new Stopped();
        }

        this.beatAt = this.now();
        await this.stream.touch(heldIds).catch((touchError: unknown) => this.log(`${this.stream.key} touch failed`, touchError));
      }
    }
  }

  private backoff(attempt: number): number {
    return fullJitter(attempt, this.options.backoffBaseMs, this.options.backoffMaxMs, this.random);
  }
}
