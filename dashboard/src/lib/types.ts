import type { CatalogEntry } from "./catalog";

export type Point = { minute: number; value: number };

export type ActivityRow = { minute: number } & Record<string, number>;

export type Outcome = "committed" | "aborted" | "pending";

export type LiveEvent = Pick<CatalogEntry, "id" | "title" | "kind" | "goal"> & {
  options: { id: string; label: string; value: number }[];
  servers: number;
};

export type DashboardData = {
  source: "live" | "demo";
  problems: string[];
  players: Point[];
  activity: { names: string[]; rows: ActivityRow[] };
  trades: {
    outcomes: Record<Outcome, number>;
    crossShare: number | null;
    p50: number | null;
    p95: number | null;
  };
  live: LiveEvent[];
};

export const RANGES = [15, 60, 360, 1440] as const;

export type Range = (typeof RANGES)[number];

export const DEFAULT_RANGE: Range = 60;
