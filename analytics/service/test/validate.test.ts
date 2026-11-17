import { describe, expect, it } from "vitest";
import { parseCatalog } from "../src/catalog.js";
import { seenKey, shardOf, streamKey } from "../src/keys.js";
import { checkWindow, parseEnvelope, validateEvent } from "../src/validate.js";
import { catalog, fixtureBatch, fixtures, invalidFixtures, validFixtures } from "./support.js";

function tradeEvent(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return { ...(validFixtures[0]?.event ?? {}), ...overrides };
}

describe("shared fixtures", () => {
  it("covers both valid and invalid events", () => {
    expect(validFixtures.length).toBeGreaterThan(0);
    expect(invalidFixtures.length).toBeGreaterThan(0);
  });

  it.each(fixtures.events.map((fixture) => [fixture.why, fixture.valid, fixture.event] as const))(
    "%s: valid = %s",
    (_why, valid, event) => {
      expect(validateEvent(event, catalog).ok).toBe(valid);
    },
  );

  it("accepts the fixture envelope", () => {
    expect(parseEnvelope(fixtureBatch(), catalog).ok).toBe(true);
  });
});

describe("envelope", () => {
  const limits = catalog.limits;
  const cases: Array<[string, unknown, string]> = [
    ["an array body", [], "not_object"],
    ["another schema version", fixtureBatch({ schema: catalog.version + 1 }), "schema"],
    ["a missing server id", fixtureBatch({ server_id: undefined }), "server_id"],
    ["an empty server id", fixtureBatch({ server_id: "" }), "server_id"],
    ["a server id over the byte limit", fixtureBatch({ server_id: "s".repeat(limits.serverIdBytes + 1) }), "server_id"],
    ["a negative place id", fixtureBatch({ place_id: -1 }), "place_id"],
    ["a fractional place id", fixtureBatch({ place_id: 1.5 }), "place_id"],
    ["a place id sent as text", fixtureBatch({ place_id: "1" }), "place_id"],
    ["a place version past UInt32", fixtureBatch({ place_version: 2 ** 32 }), "place_version"],
    ["batch_seq zero", fixtureBatch({ batch_seq: 0 }), "batch_seq"],
    ["sent_at as text", fixtureBatch({ sent_at: "now" }), "sent_at"],
    ["a negative dropped count", fixtureBatch({ dropped: -1 }), "dropped"],
    ["events that are not a list", fixtureBatch({ events: {} }), "events"],
    ["more events than the batch limit", fixtureBatch({ events: new Array(limits.batchEvents + 1).fill({}) }), "too_many_events"],
  ];

  it.each(cases)("rejects %s", (_label, body, reason) => {
    const result = parseEnvelope(body, catalog);
    expect(result).toEqual({ ok: false, reason });
  });

  it("keeps an empty batch valid", () => {
    expect(parseEnvelope(fixtureBatch({ events: [] }), catalog).ok).toBe(true);
  });
});

describe("events beyond the fixtures", () => {
  const cases: Array<[string, Record<string, unknown>, string]> = [
    ["a negative user id", tradeEvent({ user_id: -1 }), "user_id"],
    ["a fractional user id", tradeEvent({ user_id: 1.5 }), "user_id"],
    ["a session id over the byte limit", tradeEvent({ session_id: "x".repeat(catalog.limits.sessionIdBytes + 1) }), "session_id"],
    ["a weight above the maximum", tradeEvent({ weight: catalog.limits.maxWeight + 1 }), "weight"],
    ["props that are not an object", tradeEvent({ props: [] }), "props"],
    ["a negative at", tradeEvent({ at: -1 }), "at"],
    ["an infinite number prop", tradeEvent({ props: { outcome: "committed", seconds: Number.POSITIVE_INFINITY, cross_server: false } }), "not_finite"],
    ["a name that is an Object prototype key", tradeEvent({ name: "constructor" }), "unknown_event"],
    ["an event without a name", { at: 1, weight: 1, props: {} }, "unknown_event"],
  ];

  it.each(cases)("rejects %s", (_label, event, reason) => {
    expect(validateEvent(event, catalog)).toEqual({ ok: false, reason });
  });

  it("rejects an event that is not an object", () => {
    expect(validateEvent("session_start", catalog)).toEqual({ ok: false, reason: "not_object" });
  });

  it("rejects integers past the safe range", () => {
    const event = { name: "gift_sent", at: 1, weight: 1, props: { coins: 2 ** 53, items: 1 } };
    expect(validateEvent(event, catalog)).toEqual({ ok: false, reason: "integer_expected" });
  });

  it("counts string limits in UTF-8 bytes, not characters", () => {
    const characters = Math.floor(catalog.limits.stringBytes / 2) + 1;
    const event = { name: "live_reward", at: 1, weight: 1, props: { event_id: "é".repeat(characters) } };
    expect(characters).toBeLessThanOrEqual(catalog.limits.stringBytes);
    expect(validateEvent(event, catalog)).toEqual({ ok: false, reason: "string_too_long" });
  });

  it("keeps only the contract fields of a valid event", () => {
    const result = validateEvent(tradeEvent({ debug: "x", user_id: null }), catalog);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(Object.keys(result.event).sort()).toEqual(["at", "name", "props", "session_id", "weight"]);
    }
  });
});

describe("receive window", () => {
  const window = { maxAgeSeconds: 100, maxAheadSeconds: 10 };

  it("accepts events inside the window and flags the rest", () => {
    expect(checkWindow(1_000, 1_000, window)).toBeNull();
    expect(checkWindow(900, 1_000, window)).toBeNull();
    expect(checkWindow(899, 1_000, window)).toBe("stale");
    expect(checkWindow(1_011, 1_000, window)).toBe("ahead");
  });
});

describe("catalog", () => {
  it("refuses a prop type the validator does not know", () => {
    const raw = { version: 1, limits: { string_bytes: 1, server_id_bytes: 1, session_id_bytes: 1, batch_events: 1, batch_bytes: 1, max_weight: 1 }, events: { x: { props: { a: "date" } } } };
    expect(() => parseCatalog(raw)).toThrow(/unknown type/);
  });

  it("loads every event of the shared schema", () => {
    expect(catalog.events.has("trade_completed")).toBe(true);
    expect(catalog.events.get("trade_completed")?.props.get("cross_server")).toBe("boolean");
  });
});

describe("shards", () => {
  it("maps a server to one shard and keeps its dedupe key in the stream's hash slot", () => {
    const shard = shardOf("8eb8adb80e6b", 4);
    expect(shard).toBe(shardOf("8eb8adb80e6b", 4));
    expect(shard).toBeGreaterThanOrEqual(0);
    expect(shard).toBeLessThan(4);
    const tag = (key: string) => key.match(/\{([^}]*)\}/)?.[1];
    expect(tag(seenKey(shard, "8eb8adb80e6b", 7))).toBe(tag(streamKey(shard)));
  });

  it("spreads servers over every shard", () => {
    const used = new Set(Array.from({ length: 200 }, (_, n) => shardOf(`server-${n}`, 4)));
    expect(used.size).toBe(4);
  });
});
