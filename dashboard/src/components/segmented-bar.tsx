import { formatFull, formatPercent } from "@/lib/format";

export type Part = { key: string; label: string; value: number; color: string; dark?: boolean };

const LABEL_MIN_SHARE = 0.09;

export function SegmentedBar({ parts, name }: { parts: Part[]; name: string }) {
  const total = parts.reduce((sum, part) => sum + part.value, 0);
  const visible = parts.filter((part) => part.value > 0);
  const summary = parts
    .map((part) => `${part.label} ${formatFull(part.value)} (${formatPercent(total ? part.value / total : 0)})`)
    .join(", ");

  return (
    <div>
      <div role="img" aria-label={`${name}: ${summary}`} className="flex h-7 w-full gap-0.5">
        {total === 0 ? <div className="h-full w-full rounded bg-grid" /> : null}
        {visible.map((part) => {
          const share = part.value / total;
          return (
            <div
              key={part.key}
              tabIndex={0}
              title={`${part.label}: ${formatFull(part.value)} (${formatPercent(share)})`}
              className="flex h-full items-center rounded px-2 text-xs font-medium outline-offset-2 hover:brightness-110 focus-visible:outline-2"
              style={{ width: `${share * 100}%`, background: part.color, color: part.dark ? "#0b0b0b" : "#ffffff" }}
            >
              {share >= LABEL_MIN_SHARE ? formatPercent(share) : null}
            </div>
          );
        })}
      </div>
      <ul className="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-sm text-ink-2">
        {parts.map((part) => (
          <li key={part.key} className="flex items-center gap-2">
            <span className="inline-block h-2.5 w-2.5 rounded-sm" style={{ background: part.color }} />
            {part.label}
            <span className="tabular text-ink">{formatFull(part.value)}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
