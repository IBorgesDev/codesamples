import type { QueryRunner } from "./clickhouse.js";

export type OverviewRow = {
  minute: number;
  name: string;
  weighted: number;
  events: number;
  users: number;
};

export type PlayersRow = {
  minute: number;
  users: number;
};

export type Overview = {
  rows: OverviewRow[];
  players: PlayersRow[];
};

export type TradeOutcome = {
  outcome: string;
  trades: number;
  cross_server: number;
  p50: number | null;
  p95: number | null;
};

export type TradeStats = {
  trades: number;
  cross_server_share: number | null;
  seconds: { p50: number | null; p95: number | null };
  outcomes: TradeOutcome[];
};

export interface StatsSource {
  overview(minutes: number): Promise<Overview>;
  trades(minutes: number): Promise<TradeStats>;
}

const MINUTE_FILTER = `
FROM analytics.events_per_minute
WHERE minute >= toStartOfMinute(now() - toIntervalMinute({minutes:UInt32}))
`;

export const OVERVIEW_SQL = `
SELECT
    toUnixTimestamp(minute) AS minute_start,
    name,
    sum(weighted_count) AS weighted,
    sum(event_count) AS events,
    uniqMerge(users) AS users
${MINUTE_FILTER}
GROUP BY minute, name
ORDER BY minute, name
FORMAT JSON
`;

export const PLAYERS_SQL = `
SELECT
    toUnixTimestamp(minute) AS minute_start,
    uniqMerge(users) AS users
${MINUTE_FILTER}
GROUP BY minute
ORDER BY minute
FORMAT JSON
`;

const TRADE_FILTER = `
FROM analytics.events
WHERE name = 'trade_completed' AND at >= now64(3) - toIntervalMinute({minutes:UInt32})
`;

const TRADE_COLUMNS = `
    sum(weight) AS trades,
    sumIf(weight, JSONExtractBool(props, 'cross_server')) AS cross_server,
    quantiles(0.5, 0.95)(JSONExtractFloat(props, 'seconds')) AS latency
`;

export const TRADE_TOTALS_SQL = `
SELECT ${TRADE_COLUMNS}
${TRADE_FILTER}
FORMAT JSON
`;

export const TRADE_OUTCOMES_SQL = `
SELECT JSONExtractString(props, 'outcome') AS outcome, ${TRADE_COLUMNS}
${TRADE_FILTER}
GROUP BY outcome
ORDER BY trades DESC, outcome
FORMAT JSON
`;

type OverviewRecord = { minute_start: number; name: string; weighted: number; events: number; users: number };

type PlayersRecord = { minute_start: number; users: number };

type TradeRecord = { outcome?: string; trades: number; cross_server: number; latency: Array<number | null> };

function quantile(values: Array<number | null>, index: number): number | null {
  const value = values[index];
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

export class ClickHouseStats implements StatsSource {
  constructor(private readonly runner: QueryRunner) {}

  async overview(minutes: number): Promise<Overview> {
    const [rows, players] = await Promise.all([
      this.runner.query<OverviewRecord>(OVERVIEW_SQL, { minutes }),
      this.runner.query<PlayersRecord>(PLAYERS_SQL, { minutes }),
    ]);

    return {
      rows: rows.map((row) => ({
        minute: Number(row.minute_start),
        name: row.name,
        weighted: Number(row.weighted),
        events: Number(row.events),
        users: Number(row.users),
      })),
      players: players.map((row) => ({ minute: Number(row.minute_start), users: Number(row.users) })),
    };
  }

  async trades(minutes: number): Promise<TradeStats> {
    const [totals, outcomes] = await Promise.all([
      this.runner.query<TradeRecord>(TRADE_TOTALS_SQL, { minutes }),
      this.runner.query<TradeRecord>(TRADE_OUTCOMES_SQL, { minutes }),
    ]);

    const total = totals[0];
    const trades = Number(total?.trades ?? 0);
    return {
      trades,
      cross_server_share: trades > 0 ? Number(total?.cross_server ?? 0) / trades : null,
      seconds: { p50: quantile(total?.latency ?? [], 0), p95: quantile(total?.latency ?? [], 1) },
      outcomes: outcomes.map((row) => ({
        outcome: row.outcome ?? "",
        trades: Number(row.trades),
        cross_server: Number(row.cross_server),
        p50: quantile(row.latency, 0),
        p95: quantile(row.latency, 1),
      })),
    };
  }
}
