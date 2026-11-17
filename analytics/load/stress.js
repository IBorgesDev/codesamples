import http from "k6/http";
import { check } from "k6";
import { Counter } from "k6/metrics";

const URL = __ENV.ANALYTICS_URL || "http://analytics:8080";
const RATE = Number(__ENV.RATE || 500);
const DURATION = __ENV.DURATION || "45s";
const EVENTS_PER_FLUSH = Number(__ENV.EVENTS_PER_FLUSH || 40);
const VUS = Number(__ENV.VUS || Math.max(50, Math.ceil(RATE / 20)));
const PLAYERS_PER_SERVER = 8;
const FLUSH_SECONDS = 10;
const PLACE_ID = 1;
const RUN = Date.now().toString(36);

const catalog = JSON.parse(open(__ENV.SCHEMA_PATH || "/schema/events.json"));
const NAMES = Object.keys(catalog.events);
const KNOWN_VALUES = {
  trade_completed: { outcome: ["committed", "committed", "committed", "aborted", "refused"] },
  live_contribution: { event_id: ["world_fishing"] },
  live_vote: { event_id: ["boss_vote"], option: ["kraken", "megalodon", "leviathan"] },
  live_reward: { event_id: ["world_fishing", "boss_vote"] },
};

const accepted = new Counter("events_accepted");
const deferred = new Counter("batches_deferred");

const request = {
  headers: { "Content-Type": "application/json", Authorization: `Bearer ${__ENV.ANALYTICS_SERVER_TOKEN}` },
  compression: "gzip",
  tags: { name: "batch" },
};

export const options = {
  scenarios: {
    servers: {
      executor: "constant-arrival-rate",
      rate: RATE,
      timeUnit: "1s",
      duration: DURATION,
      preAllocatedVUs: VUS,
      maxVUs: VUS * 4,
      gracefulStop: "10s",
    },
  },
  summaryTrendStats: ["avg", "min", "med", "max", "p(95)", "p(99)"],
  thresholds: {
    http_req_failed: ["rate<0.001"],
    "http_req_duration{name:batch}": ["p(95)<100", "p(99)<250"],
    "http_reqs{name:batch}": ["count>0"],
  },
};

function pick(list) {
  return list[Math.floor(Math.random() * list.length)];
}

function propValue(event, type, name) {
  const known = KNOWN_VALUES[event] && KNOWN_VALUES[event][name];
  if (known) {
    return pick(known);
  }

  if (type === "boolean") {
    return Math.random() < 0.5;
  }

  if (type === "integer") {
    return Math.floor(Math.random() * 100);
  }

  if (type === "number") {
    return Math.round(Math.random() * 10000) / 1000;
  }

  return `${name}_${Math.floor(Math.random() * 8)}`.slice(0, catalog.limits.string_bytes);
}

const sequences = new Map();

export default function () {
  const slot = `${__VU}-${__ITER % 64}`;
  const seq = (sequences.get(slot) || 0) + 1;
  sequences.set(slot, seq);
  const now = Date.now() / 1000;
  const events = Array.from({ length: EVENTS_PER_FLUSH }, () => {
    const name = pick(NAMES);
    const props = {};
    for (const [prop, type] of Object.entries(catalog.events[name].props)) {
      props[prop] = propValue(name, type, prop);
    }

    const player = Math.floor(Math.random() * PLAYERS_PER_SERVER);
    return {
      name,
      at: now - Math.random() * FLUSH_SECONDS,
      user_id: __VU * 100000 + (__ITER % 64) * 100 + player,
      session_id: `${RUN}-${slot}-${player}`,
      weight: 1,
      props,
    };
  });

  const body = JSON.stringify({
    schema: catalog.version,
    server_id: `k6-${RUN}-${slot}`,
    place_id: PLACE_ID,
    place_version: 1,
    batch_seq: seq,
    sent_at: now,
    dropped: 0,
    events,
  });

  const response = http.post(`${URL}/v1/batch`, body, request);
  if (response.status === 503) {
    deferred.add(1);
  }

  if (check(response, { "batch stored": (r) => r.status === 200 })) {
    accepted.add(response.json().accepted);
  }
}

export function handleSummary(data) {
  const batch = data.metrics["http_req_duration{name:batch}"] || data.metrics.http_req_duration;
  const requests = data.metrics["http_reqs{name:batch}"] || data.metrics.http_reqs;
  const dropped = data.metrics.dropped_iterations ? data.metrics.dropped_iterations.values.count : 0;
  const acceptedEvents = data.metrics.events_accepted ? data.metrics.events_accepted.values.count : 0;
  const deferredBatches = data.metrics.batches_deferred ? data.metrics.batches_deferred.values.count : 0;
  const seconds = data.state.testRunDurationMs / 1000;
  const lines = [
    `target ${RATE} batches/s of ${EVENTS_PER_FLUSH} events for ${DURATION}`,
    `batches: ${requests.values.count} (${(requests.values.count / seconds).toFixed(0)}/s), dropped by k6: ${dropped}`,
    `batch latency p50 ${batch.values.med.toFixed(1)} ms, p95 ${batch.values["p(95)"].toFixed(1)} ms, p99 ${batch.values["p(99)"].toFixed(1)} ms, max ${batch.values.max.toFixed(1)} ms`,
    `failed: ${(data.metrics.http_req_failed.values.rate * 100).toFixed(3)}%, deferred by 503: ${deferredBatches}`,
    `events accepted: ${acceptedEvents} (${(acceptedEvents / seconds).toFixed(0)}/s)`,
  ];

  return { stdout: `\n${lines.join("\n")}\n` };
}
