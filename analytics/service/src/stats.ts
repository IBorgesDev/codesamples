import { type Fields, number, numberOrNull, query, type QueryRunner, type RowOf, text } from "./clickhouse.js";

const overviewQuery = query(
  `
  SELECT
      toUnixTimestamp(minute) AS minute_start,
      name,
      sum(weighted_count) AS weighted,
      sum(event_count) AS events,
      uniqMerge(users) AS users
  FROM analytics.events_per_minute
  WHERE minute >= toStartOfMinute(now() - toIntervalMinute({minutes:UInt32}))
  GROUP BY minute, name
  ORDER BY minute, name
  `,
  (row) => ({
    minute: number(row.minute_start),
    name: text(row.name),
    weighted: number(row.weighted),
    events: number(row.events),
    users: number(row.users),
  }),
);

const playersQuery = query(
  `
  SELECT
      toUnixTimestamp(minute) AS minute_start,
      uniqMerge(users) AS users
  FROM analytics.events_per_minute
  WHERE minute >= toStartOfMinute(now() - toIntervalMinute({minutes:UInt32}))
  GROUP BY minute
  ORDER BY minute
  `,
  (row) => ({
    minute: number(row.minute_start),
    users: number(row.users),
  }),
);

function tradeFigures(row: Fields) {
  return {
    trades: number(row.trades),
    cross_server: number(row.cross_server),
    p50: numberOrNull(row.p50),
    p95: numberOrNull(row.p95),
  };
}

const tradeTotalsQuery = query(
  `
  SELECT
      sum(weight) AS trades,
      sumIf(weight, JSONExtractBool(props, 'cross_server')) AS cross_server,
      quantile(0.5)(JSONExtractFloat(props, 'seconds')) AS p50,
      quantile(0.95)(JSONExtractFloat(props, 'seconds')) AS p95
  FROM analytics.events
  WHERE name = 'trade_completed' AND at >= now64(3) - toIntervalMinute({minutes:UInt32})
  `,
  tradeFigures,
);

const tradeOutcomesQuery = query(
  `
  SELECT
      JSONExtractString(props, 'outcome') AS outcome,
      sum(weight) AS trades,
      sumIf(weight, JSONExtractBool(props, 'cross_server')) AS cross_server,
      quantile(0.5)(JSONExtractFloat(props, 'seconds')) AS p50,
      quantile(0.95)(JSONExtractFloat(props, 'seconds')) AS p95
  FROM analytics.events
  WHERE name = 'trade_completed' AND at >= now64(3) - toIntervalMinute({minutes:UInt32})
  GROUP BY outcome
  ORDER BY trades DESC, outcome
  LIMIT 20
  `,
  (row) => ({ outcome: text(row.outcome), ...tradeFigures(row) }),
);

export type OverviewRow = RowOf<typeof overviewQuery>;
export type PlayersRow = RowOf<typeof playersQuery>;
export type TradeOutcome = RowOf<typeof tradeOutcomesQuery>;

export type Overview = {
  rows: OverviewRow[];
  players: PlayersRow[];
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

export class ClickHouseStats implements StatsSource {
  constructor(private readonly runner: QueryRunner) {}

  async overview(minutes: number): Promise<Overview> {
    const [rows, players] = await Promise.all([
      this.runner.run(overviewQuery, { minutes }),
      this.runner.run(playersQuery, { minutes }),
    ]);

    return { rows, players };
  }

  async trades(minutes: number): Promise<TradeStats> {
    const [[total], outcomes] = await Promise.all([
      this.runner.run(tradeTotalsQuery, { minutes }),
      this.runner.run(tradeOutcomesQuery, { minutes }),
    ]);

    const trades = total?.trades ?? 0;
    return {
      trades,
      cross_server_share: trades > 0 ? (total?.cross_server ?? 0) / trades : null,
      seconds: { p50: total?.p50 ?? null, p95: total?.p95 ?? null },
      outcomes,
    };
  }
}
