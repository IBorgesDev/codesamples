import { formatFull, formatPercent } from "@/lib/format";

export function GoalMeter({ value, target, label }: { value: number; target: number; label: string }) {
  const share = Math.min(1, target > 0 ? value / target : 0);

  return (
    <div>
      <div className="flex items-baseline justify-between gap-4">
        <span className="text-3xl font-semibold text-ink">{formatFull(value)}</span>
        <span className="text-sm text-ink-2">
          of {formatFull(target)} ({formatPercent(share)})
        </span>
      </div>
      <div
        role="meter"
        aria-label={label}
        aria-valuemin={0}
        aria-valuemax={target}
        aria-valuenow={value}
        className="mt-3 h-2 w-full overflow-hidden rounded-full"
        style={{ background: "var(--track)" }}
      >
        <div className="h-full rounded-full" style={{ width: `${share * 100}%`, background: "var(--series-1)" }} />
      </div>
      <div className="mt-2 text-sm text-ink-2">{label}</div>
    </div>
  );
}
