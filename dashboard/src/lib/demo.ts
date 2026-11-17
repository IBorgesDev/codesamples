import { LIVE_EVENTS, liveEventFrom } from "./catalog";
import type { ActivityRow, DashboardData, Point, Range } from "./types";

const MINUTE_MS = 60_000;
const DAY_SECONDS = 86_400;
const BASE_PLAYERS = 182_000;
const SERVERS = 22_750;
const CAUGHT_AT_MIDNIGHT = 640_000;
const CAUGHT_PER_SECOND = 4;
const VOTES = [412_380, 388_910, 201_440];
const OUTCOME_SHARES = { committed: 0.86, aborted: 0.13, pending: 0.01 };
const EVENT_SHAPES = {
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

export function demoData(range: Range, now = Date.now()): DashboardData {
  const end = Math.floor(now / MINUTE_MS) - 1;
  const players: Point[] = [];
  const rows: ActivityRow[] = [];

  for (let minute = end - range + 1; minute <= end; minute += 1) {
    const level = BASE_PLAYERS * wave(minute) * (0.97 + 0.06 * noise(minute));
    players.push({ minute: minute * MINUTE_MS, value: Math.round(level) });
    const row: ActivityRow = { minute: minute * MINUTE_MS };
    for (const [name, rate] of Object.entries(EVENT_SHAPES)) {
      row[name] = Math.round(level * rate * (0.9 + 0.2 * noise(minute * 7 + name.length)));
    }

    rows.push(row);
  }

  const trades = BASE_PLAYERS * EVENT_SHAPES.trade_completed * range;
  const caught = CAUGHT_AT_MIDNIGHT + Math.round(((now / 1000) % DAY_SECONDS) * CAUGHT_PER_SECOND);

  return {
    source: "demo",
    problems: [],
    players,
    activity: { names: Object.keys(EVENT_SHAPES), rows },
    trades: {
      outcomes: {
        committed: Math.round(trades * OUTCOME_SHARES.committed),
        aborted: Math.round(trades * OUTCOME_SHARES.aborted),
        pending: Math.round(trades * OUTCOME_SHARES.pending),
      },
      crossShare: 0.18,
      p50: 2.29,
      p95: 4.26,
    },
    live: LIVE_EVENTS.map((entry) =>
      liveEventFrom(entry, SERVERS, (_id, index) => (entry.kind === "counter" ? caught : (VOTES[index] ?? 0))),
    ),
  };
}
