"use client";

import { useEffect, useMemo, useState } from "react";
import { Card } from "@/components/card";
import { AreaTrend, type Series } from "@/components/charts";
import { GoalMeter, SegmentedBar, type Part } from "@/components/segmented-bar";
import { StatTile } from "@/components/stat-tile";
import { TableView } from "@/components/table-view";
import { EVENT_LABELS } from "@/lib/catalog";
import { formatCompact, formatFull, formatMinute, formatPercent, formatSeconds } from "@/lib/format";
import { RANGES, type DashboardData, type Range } from "@/lib/types";

const REFRESH_MS = 5_000;
const SERIES_COLORS = ["var(--series-1)", "var(--series-2)", "var(--series-3)", "var(--series-4)"];
const PANELS = 4;
const RANGE_LABELS: Record<Range, string> = { 15: "15 min", 60: "1 hour", 360: "6 hours", 1440: "24 hours" };

function useDashboard(range: Range) {
  const [data, setData] = useState<DashboardData | null>(null);
  const [loading, setLoading] = useState(true);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let cancelled = false;
    let controller = new AbortController();

    async function load() {
      controller.abort();
      controller = new AbortController();
      setLoading(true);
      try {
        const response = await fetch(`/api/dashboard?minutes=${range}`, { signal: controller.signal });
        if (!response.ok) {
          throw new Error(String(response.status));
        }

        const next = (await response.json()) as DashboardData;
        if (!cancelled) {
          setData(next);
          setFailed(false);
        }
      } catch (error) {
        if (!cancelled && !(error instanceof DOMException && error.name === "AbortError")) {
          setFailed(true);
        }
      } finally {
        if (!cancelled) {
          setLoading(false);
        }
      }
    }

    load();
    const timer = setInterval(load, REFRESH_MS);

    return () => {
      cancelled = true;
      controller.abort();
      clearInterval(timer);
    };
  }, [range]);

  return { data, loading, failed };
}

function activitySeries(data: DashboardData): { series: Series[]; rows: Record<string, number>[] } {
  const totals = data.activity.names
    .map((name) => ({ name, total: data.activity.rows.reduce((sum, row) => sum + (row[name] ?? 0), 0) }))
    .sort((a, b) => b.total - a.total);
  const top = totals.slice(0, PANELS - 1).map((entry) => entry.name);
  const rest = totals.slice(PANELS - 1).map((entry) => entry.name);
  const keys = rest.length > 0 ? [...top, "other"] : top;
  const series = keys.map((key) => ({
    key,
    label: EVENT_LABELS[key] ?? key,
    color: "var(--series-1)",
  }));
  const rows = data.activity.rows.map((row) => {
    const out: Record<string, number> = { minute: row.minute };
    for (const name of top) {
      out[name] = row[name] ?? 0;
    }

    if (rest.length > 0) {
      out.other = rest.reduce((sum, name) => sum + (row[name] ?? 0), 0);
    }

    return out;
  });

  return { series, rows };
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

export function Dashboard() {
  const [range, setRange] = useState<Range>(60);
  const { data, loading, failed } = useDashboard(range);
  const activity = useMemo(() => (data ? activitySeries(data) : null), [data]);

  const latestPlayers = data?.players.at(-1)?.value ?? 0;
  const outcomes = data?.trades.outcomes ?? { committed: 0, aborted: 0, pending: 0 };
  const tradeTotal = outcomes.committed + outcomes.aborted + outcomes.pending;
  const tradeParts: Part[] = [
    { key: "committed", label: "Committed", value: outcomes.committed, color: "var(--series-1)" },
    { key: "aborted", label: "Aborted", value: outcomes.aborted, color: "var(--series-2)" },
    { key: "pending", label: "Pending recovery", value: outcomes.pending, color: "var(--series-3)" },
  ];

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

      {data && activity ? (
        <div className={`grid gap-6 transition-opacity ${loading ? "opacity-70" : "opacity-100"}`}>
          <Card
            title="Players online"
            subtitle={`Unique players per minute, last ${RANGE_LABELS[range]}`}
            table={
              <TableView
                caption="Players online per minute"
                columns={["Minute", "Players"]}
                rows={data.players.map((point) => [formatMinute(point.minute), formatFull(point.value)])}
              />
            }
          >
            <div className="mb-2 text-5xl font-semibold text-ink">{formatFull(latestPlayers)}</div>
            <AreaTrend
              rows={data.players.map((point) => ({ minute: point.minute, players: point.value }))}
              dataKey="players"
              label="Players"
              color="var(--series-1)"
            />
          </Card>

          <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
            <StatTile label="Trades" value={formatCompact(tradeTotal)} detail={`last ${RANGE_LABELS[range]}`} />
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
                    <span className="text-sm text-ink-2">
                      {formatCompact(activity.rows.at(-1)?.[entry.key] ?? 0)} last minute
                    </span>
                  </div>
                  <AreaTrend rows={activity.rows} dataKey={entry.key} label={entry.label} color={entry.color} height={110} />
                </div>
              ))}
            </div>
          </Card>

          <div className="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
            <Card title="Trade outcomes" subtitle={`last ${RANGE_LABELS[range]}`}>
              <SegmentedBar name="Trade outcomes" parts={tradeParts} />
            </Card>

            {data.live.map((event) =>
              event.kind === "counter" && event.goal ? (
                <Card key={event.id} title={event.title} subtitle={`${formatFull(event.servers)} servers contributing`}>
                  <GoalMeter
                    value={event.options.find((option) => option.id === event.goal?.option)?.value ?? 0}
                    target={event.goal.target}
                    label={event.options.find((option) => option.id === event.goal?.option)?.label ?? event.title}
                  />
                </Card>
              ) : (
                <Card key={event.id} title={event.title} subtitle={`${formatFull(event.servers)} servers voting`}>
                  <SegmentedBar
                    name={event.title}
                    parts={event.options.map((option, index) => ({
                      key: option.id,
                      label: option.label,
                      value: option.value,
                      color: SERIES_COLORS[index],
                      dark: index === 3,
                    }))}
                  />
                </Card>
              ),
            )}
          </div>
        </div>
      ) : (
        <p className="text-sm text-ink-2">{failed ? "Could not load the dashboard." : "Loading…"}</p>
      )}
    </main>
  );
}
