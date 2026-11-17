import { LIVE_EVENTS } from "./catalog";
import type { ActivityRow, DashboardData, Point } from "./types";

const MINUTE_MS = 60_000;
const BASE_PLAYERS = 182_000;
const EVENT_SHAPES: Record<string, number> = {
  live_contribution: 0.9,
  session_start: 0.05,
  trade_completed: 0.03,
  gift_sent: 0.008,
  live_vote: 0.004,
};

function noise(seed: number): number {
  const x = Math.sin(seed * 12.9898) * 43758.5453;
  return x - Math.floor(x);
}

function wave(minute: number): number {
  const hour = (minute / 60) % 24;
  return 0.75 + 0.25 * Math.sin(((hour - 9) / 24) * Math.PI * 2);
}

export function demoData(rangeMinutes: number, now = Date.now()): DashboardData {
  const end = Math.floor(now / MINUTE_MS) - 1;
  const players: Point[] = [];
  const rows: ActivityRow[] = [];

  for (let minute = end - rangeMinutes + 1; minute <= end; minute += 1) {
    const level = BASE_PLAYERS * wave(minute) * (0.97 + 0.06 * noise(minute));
    players.push({ minute: minute * MINUTE_MS, value: Math.round(level) });
    const row: ActivityRow = { minute: minute * MINUTE_MS } as ActivityRow;
    for (const [name, rate] of Object.entries(EVENT_SHAPES)) {
      row[name] = Math.round(level * rate * (0.9 + 0.2 * noise(minute * 7 + name.length)));
    }

    rows.push(row);
  }

  const committed = Math.round(BASE_PLAYERS * 0.03 * rangeMinutes * 0.86);
  const aborted = Math.round(BASE_PLAYERS * 0.03 * rangeMinutes * 0.13);
  const pending = Math.round(BASE_PLAYERS * 0.03 * rangeMinutes * 0.01);
  const caught = 640_000 + Math.round(((now / 1000) % 86_400) * 4);

  return {
    source: "demo",
    problems: [],
    generatedAt: now,
    rangeMinutes,
    players,
    activity: { names: Object.keys(EVENT_SHAPES), rows },
    trades: { outcomes: { committed, aborted, pending }, crossShare: 0.18, p50: 2.29, p95: 4.26 },
    live: LIVE_EVENTS.map((entry) => ({
      id: entry.id,
      title: entry.title,
      kind: entry.kind,
      goal: entry.goal,
      state: "live",
      servers: 22_750,
      options: Object.entries(entry.labels).map(([id, label], index) => ({
        id,
        label,
        value: entry.kind === "counter" ? caught : [412_380, 388_910, 201_440][index] ?? 0,
      })),
    })),
  };
}
