export class BacklogMonitor {
  private value = 0;
  private checkedAt = Number.NEGATIVE_INFINITY;
  private inflight: Promise<number> | null = null;

  constructor(
    private readonly read: () => Promise<number>,
    private readonly onRead: (value: number) => void,
    private readonly intervalMs: number,
    private readonly now: () => number,
  ) {}

  current(): Promise<number> {
    if (this.now() - this.checkedAt < this.intervalMs) {
      return Promise.resolve(this.value);
    }

    if (this.inflight === null) {
      this.inflight = this.read()
        .then(
          (value) => {
            this.value = value;
            this.onRead(value);
            return value;
          },
          () => this.value,
        )
        .finally(() => {
          this.checkedAt = this.now();
          this.inflight = null;
        });
    }

    return this.inflight;
  }
}
