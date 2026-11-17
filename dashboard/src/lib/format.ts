const compact = new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 });
const full = new Intl.NumberFormat("en");
const percent = new Intl.NumberFormat("en", { style: "percent", maximumFractionDigits: 1 });
const time = new Intl.DateTimeFormat("en", { hour: "2-digit", minute: "2-digit", hour12: false });

export function formatCompact(value: number): string {
  return compact.format(value);
}

export function formatFull(value: number): string {
  return full.format(Math.round(value));
}

export function formatPercent(value: number): string {
  return percent.format(value);
}

export function formatSeconds(value: number | null): string {
  return value === null ? "–" : `${value.toFixed(2)} s`;
}

export function formatMinute(epochMs: number): string {
  return time.format(new Date(epochMs));
}
