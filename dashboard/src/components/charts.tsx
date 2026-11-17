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

function Readout({ minute, value, label, color }: { minute: number; value: number; label: string; color: string }) {
  return (
    <div className="rounded-lg bg-surface px-3 py-2 text-sm shadow-lg ring-1 ring-ring">
      <div className="mb-1 text-xs text-muted">{formatMinute(minute)}</div>
      <div className="flex items-center gap-2">
        <span className="inline-block h-0.5 w-3 rounded" style={{ background: color }} />
        <span className="tabular font-semibold text-ink">{formatFull(value)}</span>
        <span className="text-ink-2">{label}</span>
      </div>
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
            tickFormatter={formatMinute}
            tick={AXIS_TICK}
            tickLine={false}
            axisLine={{ stroke: "var(--axis)" }}
            minTickGap={48}
          />
          <YAxis
            tickFormatter={formatCompact}
            tick={AXIS_TICK}
            tickLine={false}
            axisLine={false}
            width={48}
          />
          <Tooltip
            cursor={{ stroke: "var(--axis)", strokeWidth: 1 }}
            content={({ active, label: minute, payload }) =>
              active && payload.length > 0 ? (
                <Readout minute={Number(minute)} value={Number(payload[0]?.value ?? 0)} label={label} color={color} />
              ) : null
            }
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
