import "server-only";
import { LIVE_EVENTS } from "./catalog";
import { demoData } from "./demo";
import type { ActivityRow, DashboardData, LiveEvent, Outcome, Point } from "./types";

const TIMEOUT_MS = 4_000;
const SECOND_MS = 1_000;

type OverviewResponse = {
  rows: { minute: number; name: string; weighted: number; users: number }[];
  players?: { minute: number; users: number }[];
};

type TradesResponse = {
  trades: number;
  cross_server_share: number | null;
  seconds: { p50: number | null; p95: number | null };
  outcomes: { outcome: string; trades: number }[];
};

type EventSnapshot = { state?: string; totals?: Record<string, number>; servers?: number };

async function getJson<T>(url: string, token: string): Promise<T> {
  const response = await fetch(url, {
    headers: { authorization: `Bearer ${token}` },
    cache: "no-store",
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!response.ok) {
    throw new Error(`${new URL(url).pathname} answered ${response.status}`);
  }

  return (await response.json()) as T;
}

function activityFrom(overview: OverviewResponse): { players: Point[]; names: string[]; rows: ActivityRow[] } {
  const byMinute = new Map<number, ActivityRow>();
  const names = new Set<string>();
  const usersByMinute = new Map<number, number>();

  for (const row of overview.rows) {
    const minute = row.minute * SECOND_MS;
    const entry = byMinute.get(minute) ?? ({ minute } as ActivityRow);
    entry[row.name] = row.weighted;
    byMinute.set(minute, entry);
    names.add(row.name);
    usersByMinute.set(minute, Math.max(usersByMinute.get(minute) ?? 0, row.users));
  }

  const players = overview.players
    ? overview.players.map((point) => ({ minute: point.minute * SECOND_MS, value: point.users }))
    : [...usersByMinute.entries()].map(([minute, value]) => ({ minute, value }));

  return {
    players: players.sort((a, b) => a.minute - b.minute),
    names: [...names],
    rows: [...byMinute.values()].sort((a, b) => a.minute - b.minute),
  };
}

function outcomesFrom(trades: TradesResponse): Record<Outcome, number> {
  const out: Record<Outcome, number> = { committed: 0, aborted: 0, pending: 0 };
  for (const row of trades.outcomes) {
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

async function liveEvents(problems: string[]): Promise<LiveEvent[]> {
  const url = process.env.EVENTS_URL;
  const token = process.env.EVENTS_READ_TOKEN;

  return Promise.all(
    LIVE_EVENTS.map(async (entry) => {
      let snapshot: EventSnapshot | null = null;
      if (url && token) {
        try {
          snapshot = await getJson<EventSnapshot>(`${url}/v1/events/${entry.id}`, token);
        } catch (error) {
          problems.push(`Live event ${entry.id}: ${(error as Error).message}`);
        }
      }

      return {
        id: entry.id,
        title: entry.title,
        kind: entry.kind,
        goal: entry.goal,
        state: snapshot?.state ?? "unknown",
        servers: snapshot?.servers ?? 0,
        options: Object.entries(entry.labels).map(([id, label]) => ({
          id,
          label,
          value: snapshot?.totals?.[id] ?? 0,
        })),
      };
    }),
  );
}

export async function loadDashboard(rangeMinutes: number): Promise<DashboardData> {
  const url = process.env.ANALYTICS_URL;
  const token = process.env.ANALYTICS_READ_TOKEN;
  if (!url || !token) {
    return demoData(rangeMinutes);
  }

  const problems: string[] = [];
  const [overview, trades, live] = await Promise.all([
    getJson<OverviewResponse>(`${url}/v1/stats/overview?minutes=${rangeMinutes}`, token).catch((error: Error) => {
      problems.push(`Activity: ${error.message}`);
      return null;
    }),
    getJson<TradesResponse>(`${url}/v1/stats/trades?minutes=${rangeMinutes}`, token).catch((error: Error) => {
      problems.push(`Trades: ${error.message}`);
      return null;
    }),
    liveEvents(problems),
  ]);

  const activity = overview ? activityFrom(overview) : { players: [], names: [], rows: [] };

  return {
    source: "live",
    problems,
    generatedAt: Date.now(),
    rangeMinutes,
    players: activity.players,
    activity: { names: activity.names, rows: activity.rows },
    trades: {
      outcomes: trades ? outcomesFrom(trades) : { committed: 0, aborted: 0, pending: 0 },
      crossShare: trades?.cross_server_share ?? null,
      p50: trades?.seconds.p50 ?? null,
      p95: trades?.seconds.p95 ?? null,
    },
    live,
  };
}
