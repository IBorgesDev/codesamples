import type { ClickHouseConfig } from "./config.js";
import { logger } from "./log.js";
import { isRecord } from "./record.js";

export type QueryParams = Record<string, string | number>;

export type Fields = Record<string, unknown>;

export type Query<Row> = {
  sql: string;
  row: (record: Fields) => Row;
};

export type RowOf<Q> = Q extends Query<infer Row> ? Row : never;

export type InsertResult = "stored" | "rejected";

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

class ClickHouseError extends Error {
  constructor(
    readonly status: number,
    detail: string,
  ) {
    super(`clickhouse ${status}: ${detail}`);
  }
}

const log = logger("clickhouse");

const ERROR_DETAIL_CHARS = 500;
const REFUSED_DATA = 400;
const MILLISECONDS = 1000;
const READ_ONLY_WITH_SETTINGS = "2";

export class ClickHouse implements QueryRunner {
  private readonly readSettings: Record<string, string>;

  constructor(private readonly config: ClickHouseConfig) {
    this.readSettings = {
      default_format: "JSON",
      output_format_json_quote_64bit_integers: "0",
      readonly: READ_ONLY_WITH_SETTINGS,
      cancel_http_readonly_queries_on_client_close: "1",
      max_execution_time: String(Math.max(1, Math.floor(config.timeoutMs / MILLISECONDS) - 1)),
      max_result_rows: String(config.maxResultRows),
      result_overflow_mode: "break",
    };
  }

  async insert(table: string, rows: object[], token: string): Promise<InsertResult> {
    const params = new URLSearchParams({
      query: `INSERT INTO ${table} FORMAT JSONEachRow`,
      insert_deduplicate: "1",
      insert_deduplication_token: token,
    });

    try {
      await this.send(params, rows.map((row) => JSON.stringify(row)).join("\n"));
      return "stored";
    } catch (error) {
      if (error instanceof ClickHouseError && error.status === REFUSED_DATA) {
        log("insert refused", error);
        return "rejected";
      }

      throw error;
    }
  }

  async run<Row>(definition: Query<Row>, params: QueryParams): Promise<Row[]> {
    const search = new URLSearchParams(this.readSettings);
    for (const [name, value] of Object.entries(params)) {
      search.set(`param_${name}`, String(value));
    }

    const body: unknown = JSON.parse(await this.send(search, definition.sql));
    if (!isRecord(body) || !Array.isArray(body.data) || !body.data.every(isRecord)) {
      throw new TypeError("clickhouse answered without a data array");
    }

    return body.data.map(definition.row);
  }

  private async send(params: URLSearchParams, body: string): Promise<string> {
    const url = new URL(this.config.url);
    url.search = params.toString();
    const response = await fetch(url, {
      method: "POST",
      headers: {
        "content-type": "text/plain; charset=utf-8",
        "x-clickhouse-user": this.config.user,
        "x-clickhouse-key": this.config.password,
      },
      body,
      signal: AbortSignal.timeout(this.config.timeoutMs),
    });

    const answer = await response.text();
    if (!response.ok) {
      throw new ClickHouseError(response.status, answer.slice(0, ERROR_DETAIL_CHARS));
    }

    return answer;
  }
}
