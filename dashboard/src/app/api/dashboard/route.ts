import { loadDashboard } from "@/lib/sources";
import { DEFAULT_RANGE, RANGES, type Range } from "@/lib/types";

function rangeFrom(value: string | null): Range {
  const parsed = Number(value);
  return RANGES.find((range) => range === parsed) ?? DEFAULT_RANGE;
}

export async function GET(request: Request) {
  const range = rangeFrom(new URL(request.url).searchParams.get("minutes"));
  const data = await loadDashboard(range);

  return Response.json(data, { headers: { "cache-control": "no-store" } });
}
