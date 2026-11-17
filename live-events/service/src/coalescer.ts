import type { Contribution, Snapshot } from "./store.js";

export type Batch = Map<string, Map<string, Contribution>>;

export type FlushFn = (batch: Batch) => Promise<Map<string, Snapshot | null>>;

type Cycle = {
  batch: Batch;
  waiters: Array<{ resolve: (snapshots: Map<string, Snapshot | null>) => void; reject: (error: unknown) => void }>;
};

function mergeTally(into: Record<string, number>, from: Record<string, number>) {
  for (const [option, value] of Object.entries(from)) {
    if (value > (into[option] ?? 0)) {
      into[option] = value;
    }
  }
}

export class Coalescer {
  private current: Cycle = { batch: new Map(), waiters: [] };
  private timer: NodeJS.Timeout | null = null;
  private inflight = 0;

  constructor(
    private readonly flushFn: FlushFn,
    private readonly intervalMs: number,
    private readonly maxServersPerBatch: number,
  ) {}

  add(server: string, events: Record<string, Contribution>): Promise<Map<string, Snapshot | null>> {
    const cycle = this.current;
    for (const [id, contribution] of Object.entries(events)) {
      let servers = cycle.batch.get(id);
      if (!servers) {
        servers = new Map();
        cycle.batch.set(id, servers);
      }

      const merged = servers.get(server) ?? { plus: {}, minus: {} };
      mergeTally(merged.plus, contribution.plus);
      mergeTally(merged.minus, contribution.minus);
      servers.set(server, merged);
    }

    const done = new Promise<Map<string, Snapshot | null>>((resolve, reject) => {
      cycle.waiters.push({ resolve, reject });
    });

    if (cycle.waiters.length >= this.maxServersPerBatch) {
      this.flush();
    } else if (!this.timer) {
      this.timer = setTimeout(() => this.flush(), this.intervalMs);
    }

    return done;
  }

  pending(): number {
    return this.current.waiters.length + this.inflight;
  }

  private flush() {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }

    const cycle = this.current;
    this.current = { batch: new Map(), waiters: [] };
    if (cycle.waiters.length === 0) {
      return;
    }

    this.inflight += cycle.waiters.length;
    this.flushFn(cycle.batch).then(
      (snapshots) => {
        this.inflight -= cycle.waiters.length;
        for (const waiter of cycle.waiters) {
          waiter.resolve(snapshots);
        }
      },
      (error) => {
        this.inflight -= cycle.waiters.length;
        for (const waiter of cycle.waiters) {
          waiter.reject(error);
        }
      },
    );
  }
}
