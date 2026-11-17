import "server-only";
import { LIVE_EVENTS, liveEventFrom } from "./catalog";
import { demoData } from "./demo";
import type { ActivityRow, DashboardData, LiveEvent, Outcome, Point, Range } from "./types";

const TIMEOUT_MS = 4_000;
const SECOND_MS = 1_000;
const SHARED_FOR_MS = 2_000;

type Fields = Record<string, unknown>;

type Overview = {
  rows: { minute: number; name: string; weighted: number }[];
  players: { minute: number; users: number }[];
};

type Trades = {
  crossShare: number | null;
  p50: number | null;
  p95: number | null;
  outcomes: { outcome: string; trades: number }[];
};

type Snapshot = { totals: Record<string, number>; servers: number };

function fields(value: unknown): Fields {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new TypeError("expected an object");
  }

  return value as Fields;
}

function list(value: unknown): unknown[] {
  if (!Array.isArray(value)) {
    throw new TypeError("expected an array");
  }

  return value;
}

function finite(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new TypeError("expected a number");
  }

  return value;
}

function finiteOrNull(value: unknown): number | null {
  return value === null || value === undefined ? null : finite(value);
}

function text(value: unknown): string {
  if (typeof value !== "string") {
    throw new TypeError("expected a string");
  }

  return value;
}

function overviewFrom(body: unknown): Overview {
  const overview = fields(body);
  return {
    rows: list(overview.rows).map((item) => {
      const row = fields(item);
      return { minute: finite(row.minute), name: text(row.name), weighted: finite(row.weighted) };
    }),
    players: list(overview.players).map((item) => {
      const point = fields(item);
      return { minute: finite(point.minute), users: finite(point.users) };
    }),
  };
}

function tradesFrom(body: unknown): Trades {
  const trades = fields(body);
  const seconds = fields(trades.seconds);
  return {
    crossShare: finiteOrNull(trades.cross_server_share),
    p50: finiteOrNull(seconds.p50),
    p95: finiteOrNull(seconds.p95),
    outcomes: list(trades.outcomes).map((item) => {
      const row = fields(item);
      return { outcome: text(row.outcome), trades: finite(row.trades) };
    }),
  };
}

function snapshotFrom(body: unknown): Snapshot {
  const snapshot = fields(body);
  const totals: Record<string, number> = {};
  for (const [option, value] of Object.entries(fields(snapshot.totals))) {
    totals[option] = finite(value);
  }

  return { totals, servers: finite(snapshot.servers) };
}

async function read(url: string, token: string): Promise<unknown> {
  const response = await fetch(url, {
    headers: { authorization: `Bearer ${token}` },
    cache: "no-store",
    redirect: "error",
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!response.ok) {
    throw new Error(`answered ${response.status}`);
  }

  return response.json();
}

async function attempt<T>(label: string, problems: string[], load: () => Promise<T>): Promise<T | null> {
  try {
    return await load();
  } catch (error) {
    console.error(`dashboard: ${label} failed`, error);
    problems.push(`${label} unavailable`);
    return null;
  }
}

function activityFrom(overview: Overview): { players: Point[]; names: string[]; rows: ActivityRow[] } {
  const byMinute = new Map<number, ActivityRow>();
  const names = new Set<string>();

  for (const row of overview.rows) {
    const minuteMs = row.minute * SECOND_MS;
    const entry = byMinute.get(minuteMs) ?? { minute: minuteMs };
    entry[row.name] = row.weighted;
    byMinute.set(minuteMs, entry);
    names.add(row.name);
  }

  return {
    players: overview.players
      .map((point) => ({ minute: point.minute * SECOND_MS, value: point.users }))
      .sort((a, b) => a.minute - b.minute),
    names: [...names],
    rows: [...byMinute.values()].sort((a, b) => a.minute - b.minute),
  };
}

function outcomesFrom(rows: Trades["outcomes"]): Record<Outcome, number> {
  const out: Record<Outcome, number> = { committed: 0, aborted: 0, pending: 0 };
  for (const row of rows) {
    if (row.outcome === "committed") {
      out.committed += row.trades;
    } else if (row.outcome === "aborted" || row.outcome === "refused") {
      out.aborted += row.trades;
    } else {
      out.pending += row.trades;
    }
  }

  return out;
}

function liveEvents(problems: string[]): Promise<LiveEvent[]> {
  const url = process.env.EVENTS_URL;
  const token = process.env.EVENTS_READ_TOKEN;

  return Promise.all(
    LIVE_EVENTS.map(async (entry) => {
      const snapshot =
        url && token
          ? await attempt(`Live event ${entry.id}`, problems, async () =>
              snapshotFrom(await read(`${url}/v1/events/${entry.id}`, token)),
            )
          : null;

      return liveEventFrom(entry, snapshot?.servers ?? 0, (id) => snapshot?.totals[id] ?? 0);
    }),
  );
}

async function load(range: Range): Promise<DashboardData> {
  const url = process.env.ANALYTICS_URL;
  const token = process.env.ANALYTICS_READ_TOKEN;
  if (!url || !token) {
    return demoData(range);
  }

  const problems: string[] = [];
  const [overview, trades, live] = await Promise.all([
    attempt("Activity", problems, async () => overviewFrom(await read(`${url}/v1/stats/overview?minutes=${range}`, token))),
    attempt("Trades", problems, async () => tradesFrom(await read(`${url}/v1/stats/trades?minutes=${range}`, token))),
    liveEvents(problems),
  ]);

  const activity = activityFrom(overview ?? { rows: [], players: [] });

  return {
    source: "live",
    problems,
    players: activity.players,
    activity: { names: activity.names, rows: activity.rows },
    trades: {
      outcomes: outcomesFrom(trades?.outcomes ?? []),
      crossShare: trades?.crossShare ?? null,
      p50: trades?.p50 ?? null,
      p95: trades?.p95 ?? null,
    },
    live,
  };
}

const shared = new Map<Range, { at: number; data: Promise<DashboardData> }>();

export function loadDashboard(range: Range, now = Date.now()): Promise<DashboardData> {
  const current = shared.get(range);
  if (current && now - current.at < SHARED_FOR_MS) {
    return current.data;
  }

  const data = load(range);
  shared.set(range, { at: now, data });
  data.catch(() => shared.delete(range));

  return data;
}
