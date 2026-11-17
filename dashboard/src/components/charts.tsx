"use client";

import {
  Area,
  AreaChart,
  CartesianGrid,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { formatCompact, formatFull, formatMinute } from "@/lib/format";

export type Series = { key: string; label: string; color: string };

type TooltipRow = { dataKey?: unknown; value?: unknown };

function Readout({
  active,
  label,
  payload,
  series,
}: {
  active?: boolean;
  label?: unknown;
  payload?: readonly TooltipRow[];
  series: Series[];
}) {
  if (!active || !payload || payload.length === 0) {
    return null;
  }

  return (
    <div className="rounded-lg bg-surface px-3 py-2 text-sm shadow-lg ring-1 ring-ring">
      <div className="mb-1 text-xs text-muted">{formatMinute(Number(label))}</div>
      {series.map((entry) => {
        const row = payload.find((item) => item.dataKey === entry.key);
        return (
          <div key={entry.key} className="flex items-center gap-2">
            <span className="inline-block h-0.5 w-3 rounded" style={{ background: entry.color }} />
            <span className="tabular font-semibold text-ink">{formatFull(Number(row?.value ?? 0))}</span>
            <span className="text-ink-2">{entry.label}</span>
          </div>
        );
      })}
    </div>
  );
}

const AXIS_TICK = { fill: "var(--muted)", fontSize: 12 };

export function AreaTrend({
  rows,
  dataKey,
  label,
  color,
  height = 140,
}: {
  rows: Record<string, number>[];
  dataKey: string;
  label: string;
  color: string;
  height?: number;
}) {
  const series = [{ key: dataKey, label, color }];

  return (
    <div style={{ height }}>
      <ResponsiveContainer width="100%" height="100%">
        <AreaChart data={rows} margin={{ top: 8, right: 16, bottom: 0, left: 0 }}>
          <CartesianGrid vertical={false} stroke="var(--grid)" strokeWidth={1} />
          <XAxis
            dataKey="minute"
            type="number"
            scale="time"
            domain={["dataMin", "dataMax"]}
            tickFormatter={(value: number) => formatMinute(value)}
            tick={AXIS_TICK}
            tickLine={false}
            axisLine={{ stroke: "var(--axis)" }}
            minTickGap={48}
          />
          <YAxis
            tickFormatter={(value: number) => formatCompact(value)}
            tick={AXIS_TICK}
            tickLine={false}
            axisLine={false}
            width={48}
          />
          <Tooltip
            cursor={{ stroke: "var(--axis)", strokeWidth: 1 }}
            content={(props) => (
              <Readout
                active={props.active}
                label={props.label}
                payload={props.payload as readonly TooltipRow[] | undefined}
                series={series}
              />
            )}
          />
          <Area
            type="monotone"
            dataKey={dataKey}
            stroke={color}
            strokeWidth={2}
            fill={color}
            fillOpacity={0.1}
            activeDot={{ r: 4, stroke: "var(--surface)", strokeWidth: 2, fill: color }}
            isAnimationActive={false}
          />
        </AreaChart>
      </ResponsiveContainer>
    </div>
  );
}
