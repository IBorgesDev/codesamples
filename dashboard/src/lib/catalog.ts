export type CatalogEntry = {
  id: string;
  title: string;
  kind: "counter" | "vote";
  labels: Record<string, string>;
  goal: { option: string; target: number } | null;
};

export const LIVE_EVENTS: CatalogEntry[] = [
  {
    id: "world_fishing",
    title: "World Fishing Event",
    kind: "counter",
    labels: { fish: "Fish caught worldwide" },
    goal: { option: "fish", target: 1_000_000 },
  },
  {
    id: "boss_vote",
    title: "Choose the next boss",
    kind: "vote",
    labels: { kraken: "Kraken", megalodon: "Megalodon", leviathan: "Leviathan" },
    goal: null,
  },
];

export const EVENT_LABELS: Record<string, string> = {
  session_start: "Sessions started",
  session_end: "Sessions ended",
  trade_completed: "Trades",
  gift_sent: "Gifts",
  live_contribution: "Event contributions",
  live_vote: "Votes",
  live_reward: "Rewards",
  purchase: "Purchases",
  other: "Other",
};
