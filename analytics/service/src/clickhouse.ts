import type { ClickHouseConfig } from "./config.js";

export type Fetch = typeof fetch;

export type QueryParams = Record<string, string | number>;

export type Fields = Record<string, unknown>;

export type Query<Row> = {
  sql: string;
  row: (record: Fields) => Row;
};

export type RowOf<Q> = Q extends Query<infer Row> ? Row : never;

export interface QueryRunner {
  run<Row>(query: Query<Row>, params: QueryParams): Promise<Row[]>;
}

export function query<Row>(sql: string, row: (record: Fields) => Row): Query<Row> {
  return { sql, row };
}

export function number(value: unknown): number {
  const parsed = typeof value === "string" ? Number(value) : value;
  if (typeof parsed !== "number" || !Number.isFinite(parsed)) {
    throw new TypeError(`expected a number, got ${String(value)}`);
  }

  return parsed;
}

export function numberOrNull(value: unknown): number | null {
  const parsed = typeof value === "string" ? Number(value) : value;
  return typeof parsed === "number" && Number.isFinite(parsed) ? parsed : null;
}

export function text(value: unknown): string {
  if (typeof value !== "string") {
    throw new TypeError(`expected a string, got ${String(value)}`);
  }

  return value;
}

export class ClickHouseError extends Error {
  constructor(
    readonly status: number,
    detail: string,
  ) {
    super(`clickhouse ${status}: ${detail}`);
  }
}

const ERROR_DETAIL_CHARS = 500;

export class ClickHouse implements QueryRunner {
  constructor(
    private readonly config: ClickHouseConfig,
    private readonly fetchFn: Fetch = fetch,
  ) {}

  async insert(table: string, rows: object[], token: string): Promise<void> {
    const params = new URLSearchParams({
      query: `INSERT INTO ${table} FORMAT JSONEachRow`,
      insert_deduplicate: "1",
      insert_deduplication_token: token,
    });

    await this.send(params, rows.map((row) => JSON.stringify(row)).join("\n"));
  }

  async run<Row>(definition: Query<Row>, params: QueryParams): Promise<Row[]> {
    const search = new URLSearchParams({ default_format: "JSON", output_format_json_quote_64bit_integers: "0" });
    for (const [name, value] of Object.entries(params)) {
      search.set(`param_${name}`, String(value));
    }

    const body = JSON.parse(await this.send(search, definition.sql)) as { data: Fields[] };
    return body.data.map(definition.row);
  }

  async execute(sql: string): Promise<void> {
    await this.send(new URLSearchParams(), sql);
  }

  async ping(): Promise<boolean> {
    try {
      const response = await this.fetchFn(new URL("/ping", this.config.url), { signal: AbortSignal.timeout(this.config.timeoutMs) });
      return response.ok;
    } catch {
      return false;
    }
  }

  private async send(params: URLSearchParams, body: string): Promise<string> {
    const url = new URL(this.config.url);
    url.search = params.toString();
    const response = await this.fetchFn(url, {
      method: "POST",
      headers: {
        "content-type": "text/plain; charset=utf-8",
        "x-clickhouse-user": this.config.user,
        "x-clickhouse-key": this.config.password,
      },
      body,
      signal: AbortSignal.timeout(this.config.timeoutMs),
    });

    const text = await response.text();
    if (!response.ok) {
      throw new ClickHouseError(response.status, text.slice(0, ERROR_DETAIL_CHARS));
    }

    return text;
  }
}
