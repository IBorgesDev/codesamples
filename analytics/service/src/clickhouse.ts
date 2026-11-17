import type { ClickHouseConfig } from "./config.js";

export type Fetch = typeof fetch;

export type QueryParams = Record<string, string | number>;

export interface QueryRunner {
  query<T>(sql: string, params: QueryParams): Promise<T[]>;
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

  async query<T>(sql: string, params: QueryParams): Promise<T[]> {
    const search = new URLSearchParams({ output_format_json_quote_64bit_integers: "0" });
    for (const [name, value] of Object.entries(params)) {
      search.set(`param_${name}`, String(value));
    }

    const text = await this.send(search, sql);
    return (JSON.parse(text) as { data: T[] }).data;
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
