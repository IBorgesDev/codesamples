import { createHash } from "node:crypto";
import { setTimeout as delay } from "node:timers/promises";
import { decodeBatch, type EventRow, toRows } from "./batch.js";
import type { WorkerMetrics } from "./metrics.js";
import { isMissingGroup, type RawEntry } from "./redis.js";

export type ShardEntry = RawEntry;

export interface ShardStream {
  readonly key: string;
  ensureGroup(): Promise<void>;
  readPending(count: number): Promise<ShardEntry[]>;
  readNew(count: number, blockMs: number): Promise<ShardEntry[]>;
  reclaim(minIdleMs: number, count: number): Promise<ShardEntry[]>;
  touch(ids: string[]): Promise<void>;
  ack(ids: string[]): Promise<void>;
}

export interface RowSink {
  insert(rows: EventRow[], token: string): Promise<void>;
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
  log?: (message: string, error: unknown) => void;
};

export class Stopped extends Error {
  constructor() {
    super("worker stopped");
  }
}

export const sleepUnlessStopped: Sleep = async (ms, signal) => {
  try {
    await delay(ms, undefined, { signal });
  } catch {
    return;
  }
};

export function dedupToken(streamKey: string, ids: string[]): string {
  return `${streamKey}:${ids.length}:${createHash("sha256").update(ids.join(",")).digest("hex")}`;
}

export function fullJitter(attempt: number, baseMs: number, maxMs: number, random: () => number): number {
  return random() * Math.min(maxMs, baseMs * 2 ** attempt);
}

export class ShardWorker {
  private drainingOwnPending = true;
  private lastReclaimAt = Number.NEGATIVE_INFINITY;
  private beatAt: number;
  private readonly now: () => number;
  private readonly sleep: Sleep;
  private readonly random: () => number;
  private readonly log: (message: string, error: unknown) => void;

  constructor(
    private readonly stream: ShardStream,
    private readonly sink: RowSink,
    private readonly metrics: WorkerMetrics,
    private readonly options: ShardWorkerOptions,
  ) {
    this.now = options.now ?? Date.now;
    this.sleep = options.sleep ?? sleepUnlessStopped;
    this.random = options.random ?? Math.random;
    this.log = options.log ?? ((message, error) => console.error(`analytics-worker: ${message}`, error));
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

        this.metrics.failures.labels("read").inc();
        this.log(`${this.stream.key} step failed`, error);
        await this.sleep(this.backoff(failures), signal);
        failures += 1;
      }

      this.beatAt = this.now();
    }
  }

  async step(signal?: AbortSignal): Promise<number> {
    let entries: ShardEntry[];
    let reclaimed = false;
    if (this.drainingOwnPending) {
      entries = await this.stream.readPending(this.options.readCount);
      if (entries.length === 0) {
        this.drainingOwnPending = false;
        return 0;
      }
    } else if (this.now() - this.lastReclaimAt >= this.options.reclaimEveryMs) {
      this.lastReclaimAt = this.now();
      entries = await this.stream.reclaim(this.options.claimIdleMs, this.options.readCount);
      reclaimed = entries.length > 0;
      if (!reclaimed) {
        entries = await this.stream.readNew(this.options.readCount, this.options.blockMs);
      }
    } else {
      entries = await this.stream.readNew(this.options.readCount, this.options.blockMs);
    }

    if (entries.length === 0) {
      return 0;
    }

    if (reclaimed) {
      this.metrics.reclaimed.inc(entries.length);
    }

    await this.deliver(entries, signal);
    return entries.length;
  }

  private async deliver(entries: ShardEntry[], signal?: AbortSignal): Promise<void> {
    const ids = entries.map((entry) => entry.id);
    const rows: EventRow[] = [];
    let malformed = 0;
    for (const entry of entries) {
      const batch = decodeBatch(entry.batch);
      if (batch === null) {
        malformed += 1;
        continue;
      }

      rows.push(...toRows(batch));
    }

    if (malformed > 0) {
      this.metrics.malformed.inc(malformed);
    }

    if (rows.length > 0) {
      const token = dedupToken(this.stream.key, ids);
      await this.retry("insert", ids, signal, async () => {
        const stopTimer = this.metrics.insertSeconds.startTimer();
        await this.sink.insert(rows, token);
        stopTimer();
      });
      this.metrics.rows.inc(rows.length);
    }

    await this.retry("ack", ids, signal, () => this.stream.ack(ids));
    this.metrics.entries.inc(ids.length);
  }

  private async retry(stage: string, ids: string[], signal: AbortSignal | undefined, action: () => Promise<void>): Promise<void> {
    for (let attempt = 0; ; attempt++) {
      try {
        await action();
        return;
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
        await this.stream.touch(ids).catch((touchError: unknown) => this.log(`${this.stream.key} touch failed`, touchError));
      }
    }
  }

  private backoff(attempt: number): number {
    return fullJitter(attempt, this.options.backoffBaseMs, this.options.backoffMaxMs, this.random);
  }
}
