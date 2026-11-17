import { type Contribution, emptyTally, type Snapshot, type Tally } from "./store.js";

export type Batch = Map<string, Map<string, Contribution>>;

export type FlushFn = (batch: Batch) => Promise<Map<string, Snapshot | null>>;

type Cycle = {
  batch: Batch;
  fields: number;
  waiters: Array<{ resolve: (snapshots: Map<string, Snapshot | null>) => void; reject: (error: unknown) => void }>;
};

function emptyCycle(): Cycle {
  return { batch: new Map(), fields: 0, waiters: [] };
}

function mergeTally(into: Tally, from: Tally): number {
  const entries = Object.entries(from);
  for (const [option, value] of entries) {
    if (value > (into[option] ?? 0)) {
      into[option] = value;
    }
  }

  return entries.length;
}

export class Coalescer {
  private current = emptyCycle();
  private timer: NodeJS.Timeout | null = null;

  constructor(
    private readonly flushFn: FlushFn,
    private readonly intervalMs: number,
    private readonly maxRequests: number,
    private readonly maxFields: number,
  ) {}

  add(server: string, events: Record<string, Contribution>): Promise<Map<string, Snapshot | null>> {
    const cycle = this.current;
    for (const [id, contribution] of Object.entries(events)) {
      let servers = cycle.batch.get(id);
      if (!servers) {
        servers = new Map();
        cycle.batch.set(id, servers);
      }

      const merged = servers.get(server) ?? { plus: emptyTally(), minus: emptyTally() };
      cycle.fields += mergeTally(merged.plus, contribution.plus) + mergeTally(merged.minus, contribution.minus);
      servers.set(server, merged);
    }

    const done = new Promise<Map<string, Snapshot | null>>((resolve, reject) => {
      cycle.waiters.push({ resolve, reject });
    });

    if (cycle.waiters.length >= this.maxRequests || cycle.fields >= this.maxFields) {
      this.flush();
    } else if (!this.timer) {
      this.timer = setTimeout(() => this.flush(), this.intervalMs);
    }

    return done;
  }

  private flush() {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }

    const cycle = this.current;
    this.current = emptyCycle();
    if (cycle.waiters.length === 0) {
      return;
    }

    this.flushFn(cycle.batch).then(
      (snapshots) => cycle.waiters.forEach((waiter) => waiter.resolve(snapshots)),
      (error: unknown) => cycle.waiters.forEach((waiter) => waiter.reject(error)),
    );
  }
}
