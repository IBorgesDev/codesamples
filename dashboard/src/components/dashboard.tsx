"use client";

import { useEffect, useMemo, useState } from "react";
import { Card } from "@/components/card";
import { AreaTrend } from "@/components/charts";
import { GoalMeter } from "@/components/goal-meter";
import { SegmentedBar, type Part } from "@/components/segmented-bar";
import { StatTile } from "@/components/stat-tile";
import { TableView } from "@/components/table-view";
import { EVENT_LABELS } from "@/lib/catalog";
import { formatCompact, formatFull, formatMinute, formatPercent, formatSeconds } from "@/lib/format";
import { DEFAULT_RANGE, RANGES, type DashboardData, type LiveEvent, type Range } from "@/lib/types";

const REFRESH_MS = 5_000;
const ACTIVITY_PANELS = 4;
const TREND_COLOR = "var(--series-1)";
const VOTE_SERIES = [
  { color: "var(--series-1)" },
  { color: "var(--series-2)" },
  { color: "var(--series-3)" },
  { color: "var(--series-4)", dark: true },
];
const RANGE_LABELS: Record<Range, string> = { 15: "15 min", 60: "1 hour", 360: "6 hours", 1440: "24 hours" };

type Series = { key: string; label: string };

function useDashboard(range: Range) {
  const [data, setData] = useState<DashboardData | null>(null);
  const [loading, setLoading] = useState(true);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let current = new AbortController();

    async function load() {
      if (document.hidden) {
        return;
      }

      current.abort();
      const controller = new AbortController();
      current = controller;
      setLoading(true);
      try {
        const response = await fetch(`/api/dashboard?minutes=${range}`, { signal: controller.signal });
        if (!response.ok) {
          throw new Error(String(response.status));
        }

        const next = (await response.json()) as DashboardData;
        if (!controller.signal.aborted) {
          setData(next);
          setFailed(false);
          setLoading(false);
        }
      } catch {
        if (!controller.signal.aborted) {
          setFailed(true);
          setLoading(false);
        }
      }
    }

    load();
    const timer = setInterval(load, REFRESH_MS);
    document.addEventListener("visibilitychange", load);

    return () => {
      current.abort();
      clearInterval(timer);
      document.removeEventListener("visibilitychange", load);
    };
  }, [range]);

  return { data, loading, failed };
}

function activitySeries(activity: DashboardData["activity"]): { series: Series[]; rows: Record<string, number>[] } {
  const totals = activity.names
    .map((name) => ({ name, total: activity.rows.reduce((sum, row) => sum + (row[name] ?? 0), 0) }))
    .sort((a, b) => b.total - a.total);
  const top = totals.slice(0, ACTIVITY_PANELS - 1).map((entry) => entry.name);
  const rest = totals.slice(ACTIVITY_PANELS - 1).map((entry) => entry.name);
  const keys = rest.length > 0 ? [...top, "other"] : top;
  const rows = activity.rows.map((row) => {
    const out: Record<string, number> = { minute: row.minute };
    for (const name of top) {
      out[name] = row[name] ?? 0;
    }

    if (rest.length > 0) {
      out.other = rest.reduce((sum, name) => sum + (row[name] ?? 0), 0);
    }

    return out;
  });

  return { series: keys.map((key) => ({ key, label: EVENT_LABELS[key] ?? key })), rows };
}

function RangePicker({ value, onChange }: { value: Range; onChange: (range: Range) => void }) {
  return (
    <div role="radiogroup" aria-label="Time range" className="flex gap-1 rounded-lg bg-surface p-1 ring-1 ring-ring">
      {RANGES.map((range) => (
        <button
          key={range}
          type="button"
          role="radio"
          aria-checked={value === range}
          onClick={() => onChange(range)}
          className={`rounded-md px-3 py-1 text-sm ${
            value === range ? "bg-page font-semibold text-ink ring-1 ring-ring" : "text-ink-2 hover:bg-page"
          }`}
        >
          {RANGE_LABELS[range]}
        </button>
      ))}
    </div>
  );
}

function LiveEventCard({ event }: { event: LiveEvent }) {
  const goal = event.goal;
  if (event.kind === "counter" && goal) {
    const counted = event.options.find((option) => option.id === goal.option);
    return (
      <Card title={event.title} subtitle={`${formatFull(event.servers)} servers contributing`}>
        <GoalMeter value={counted?.value ?? 0} target={goal.target} label={counted?.label ?? event.title} />
      </Card>
    );
  }

  return (
    <Card title={event.title} subtitle={`${formatFull(event.servers)} servers voting`}>
      <SegmentedBar
        name={event.title}
        parts={event.options.map((option, index) => ({
          key: option.id,
          label: option.label,
          value: option.value,
          ...VOTE_SERIES[index % VOTE_SERIES.length],
        }))}
      />
    </Card>
  );
}

function DashboardPanels({ data, range, loading }: { data: DashboardData; range: Range; loading: boolean }) {
  const activity = useMemo(() => activitySeries(data.activity), [data.activity]);
  const period = `last ${RANGE_LABELS[range]}`;
  const { outcomes } = data.trades;
  const tradeTotal = outcomes.committed + outcomes.aborted + outcomes.pending;
  const tradeParts: Part[] = [
    { key: "committed", label: "Committed", value: outcomes.committed, color: "var(--series-1)" },
    { key: "aborted", label: "Aborted", value: outcomes.aborted, color: "var(--series-2)" },
    { key: "pending", label: "Pending recovery", value: outcomes.pending, color: "var(--series-3)" },
  ];

  return (
    <div className={`grid gap-6 transition-opacity ${loading ? "opacity-70" : "opacity-100"}`}>
      <Card
        title="Players online"
        subtitle={`Unique players per minute, ${period}`}
        table={
          <TableView
            caption="Players online per minute"
            columns={["Minute", "Players"]}
            rows={data.players.map((point) => [formatMinute(point.minute), formatFull(point.value)])}
          />
        }
      >
        <div className="mb-2 text-5xl font-semibold text-ink">{formatFull(data.players.at(-1)?.value ?? 0)}</div>
        <AreaTrend
          rows={data.players.map((point) => ({ minute: point.minute, players: point.value }))}
          dataKey="players"
          label="Players"
          color={TREND_COLOR}
        />
      </Card>

      <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
        <StatTile label="Trades" value={formatCompact(tradeTotal)} detail={period} />
        <StatTile
          label="Committed"
          value={tradeTotal ? formatPercent(outcomes.committed / tradeTotal) : "–"}
          detail="of finished trades"
        />
        <StatTile
          label="Across servers"
          value={data.trades.crossShare === null ? "–" : formatPercent(data.trades.crossShare)}
          detail="of all trades"
        />
        <StatTile
          label="Wait for the result"
          value={formatSeconds(data.trades.p50)}
          detail={`p50, p95 ${formatSeconds(data.trades.p95)}`}
        />
      </div>

      <Card
        title="Activity"
        subtitle="Events per minute, each on its own scale; sampled events scaled by their weight"
        table={
          <TableView
            caption="Events per minute"
            columns={["Minute", ...activity.series.map((entry) => entry.label)]}
            rows={activity.rows.map((row) => [
              formatMinute(row.minute),
              ...activity.series.map((entry) => formatFull(row[entry.key] ?? 0)),
            ])}
          />
        }
      >
        <div className="grid gap-6 sm:grid-cols-2">
          {activity.series.map((entry) => (
            <div key={entry.key}>
              <div className="flex items-baseline justify-between gap-2">
                <h3 className="text-sm font-medium text-ink">{entry.label}</h3>
                <span className="text-sm text-ink-2">{formatCompact(activity.rows.at(-1)?.[entry.key] ?? 0)} last minute</span>
              </div>
              <AreaTrend rows={activity.rows} dataKey={entry.key} label={entry.label} color={TREND_COLOR} height={110} />
            </div>
          ))}
        </div>
      </Card>

      <div className="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
        <Card title="Trade outcomes" subtitle={period}>
          <SegmentedBar name="Trade outcomes" parts={tradeParts} />
        </Card>

        {data.live.map((event) => (
          <LiveEventCard key={event.id} event={event} />
        ))}
      </div>
    </div>
  );
}

export function Dashboard() {
  const [range, setRange] = useState<Range>(DEFAULT_RANGE);
  const { data, loading, failed } = useDashboard(range);

  return (
    <main className="mx-auto max-w-6xl px-6 py-8">
      <header className="mb-6 flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-xl font-semibold text-ink">Live Ops Dashboard</h1>
          <p className="text-sm text-ink-2">Players, trades and global events across every server</p>
        </div>
        <div className="flex items-center gap-2 text-xs text-ink-2">
          {data ? (
            <span className="rounded-full px-2 py-0.5 ring-1 ring-ring">
              {data.source === "demo" ? "Demo data: no analytics service configured" : "Live data"}
            </span>
          ) : null}
          {failed ? <span className="rounded-full px-2 py-0.5 ring-1 ring-ring">Refresh failed, showing the last data</span> : null}
        </div>
      </header>

      <div className="mb-6">
        <RangePicker value={range} onChange={setRange} />
      </div>

      {data && data.problems.length > 0 ? (
        <ul className="mb-6 rounded-lg bg-surface p-3 text-sm text-ink-2 ring-1 ring-ring">
          {data.problems.map((problem) => (
            <li key={problem}>{problem}</li>
          ))}
        </ul>
      ) : null}

      {data ? (
        <DashboardPanels data={data} range={range} loading={loading} />
      ) : (
        <p className="text-sm text-ink-2">{failed ? "Could not load the dashboard." : "Loading…"}</p>
      )}
    </main>
  );
}
