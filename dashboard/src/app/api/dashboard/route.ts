import { loadDashboard } from "@/lib/sources";
import { RANGES, type Range } from "@/lib/types";

const DEFAULT_RANGE: Range = 60;

function rangeFrom(value: string | null): Range {
  const parsed = Number(value);
  return (RANGES as readonly number[]).includes(parsed) ? (parsed as Range) : DEFAULT_RANGE;
}

export async function GET(request: Request) {
  const range = rangeFrom(new URL(request.url).searchParams.get("minutes"));
  const data = await loadDashboard(range);

  return Response.json(data, { headers: { "cache-control": "no-store" } });
}
