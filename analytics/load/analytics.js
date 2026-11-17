import http from "k6/http";
import { check, sleep } from "k6";
import { Counter } from "k6/metrics";

const URL = __ENV.ANALYTICS_URL || "http://analytics:8080";
const SERVERS = Number(__ENV.SERVERS || 1250);
const FLUSH_SECONDS = Number(__ENV.FLUSH_SECONDS || 5);
const EVENTS_PER_FLUSH = Number(__ENV.EVENTS_PER_FLUSH || 40);
const DURATION = __ENV.DURATION || "2m";
const PLAYERS_PER_SERVER = 40;
const MAX_ATTEMPTS = 5;
const RETRY_AFTER_CAP_SECONDS = 10;
const PLACE_ID = Number(__ENV.PLACE_ID || 1);
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
const rejected = new Counter("events_rejected");
const duplicates = new Counter("batches_duplicate");
const deferred = new Counter("batches_deferred");
const abandoned = new Counter("batches_abandoned");

const request = {
  headers: { "Content-Type": "application/json", Authorization: `Bearer ${__ENV.ANALYTICS_SERVER_TOKEN}` },
  compression: "gzip",
  tags: { name: "batch" },
};

export const options = {
  scenarios: {
    servers: {
      executor: "constant-vus",
      vus: SERVERS,
      duration: DURATION,
      gracefulStop: "30s",
    },
  },
  summaryTrendStats: ["avg", "min", "med", "max", "p(95)", "p(99)"],
  thresholds: {
    http_req_failed: ["rate<0.001"],
    "http_req_duration{name:batch}": ["p(95)<100", "p(99)<250"],
    checks: ["rate>0.999"],
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

function randomEvent(now) {
  const name = pick(NAMES);
  const props = {};
  for (const [prop, type] of Object.entries(catalog.events[name].props)) {
    props[prop] = propValue(name, type, prop);
  }

  const player = Math.floor(Math.random() * PLAYERS_PER_SERVER);
  return {
    name,
    at: now - Math.random() * FLUSH_SECONDS,
    user_id: __VU * 1000 + player,
    session_id: `${RUN}-${__VU}-${player}`,
    weight: 1,
    props,
  };
}

let seq = 0;

export default function () {
  if (seq === 0) {
    sleep(Math.random() * FLUSH_SECONDS);
  }

  seq += 1;
  const now = Date.now() / 1000;
  const events = Array.from({ length: EVENTS_PER_FLUSH }, () => randomEvent(now));
  const body = JSON.stringify({
    schema: catalog.version,
    server_id: `k6-${RUN}-${__VU}`,
    place_id: PLACE_ID,
    place_version: 1,
    batch_seq: seq,
    sent_at: now,
    dropped: 0,
    events,
  });

  let response = null;
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    response = http.post(`${URL}/v1/batch`, body, request);
    if (response.status === 200) {
      break;
    }

    if (response.status === 503) {
      deferred.add(1);
    }

    const retryAfter = Number(response.headers["Retry-After"] || 0);
    const backoff = retryAfter > 0 ? Math.min(retryAfter, RETRY_AFTER_CAP_SECONDS) : 0.2 * Math.pow(2, attempt);
    sleep(Math.random() * backoff);
  }

  const ok = check(response, { "batch stored": (r) => r !== null && r.status === 200 });
  if (ok) {
    const result = response.json();
    accepted.add(result.accepted);
    rejected.add(result.rejected);
    if (result.duplicate) {
      duplicates.add(1);
    }
  } else {
    abandoned.add(1);
  }

  sleep(FLUSH_SECONDS * (0.8 + Math.random() * 0.4));
}

function count(data, name) {
  return data.metrics[name] ? data.metrics[name].values.count : 0;
}

export function handleSummary(data) {
  const batch = data.metrics["http_req_duration{name:batch}"] || data.metrics.http_req_duration;
  const requests = data.metrics.http_reqs.values;
  const acceptedEvents = count(data, "events_accepted");
  const seconds = data.state.testRunDurationMs / 1000;
  const lines = [
    `servers (VUs): ${SERVERS}, flush every ~${FLUSH_SECONDS}s with ${EVENTS_PER_FLUSH} events, ${DURATION}`,
    `requests: ${requests.count} (${requests.rate.toFixed(0)}/s)`,
    `batch latency p50 ${batch.values.med.toFixed(1)} ms, p95 ${batch.values["p(95)"].toFixed(1)} ms, p99 ${batch.values["p(99)"].toFixed(1)} ms, max ${batch.values.max.toFixed(1)} ms`,
    `failed: ${(data.metrics.http_req_failed.values.rate * 100).toFixed(3)}%`,
    `events accepted: ${acceptedEvents} (${(acceptedEvents / seconds).toFixed(0)}/s), rejected: ${count(data, "events_rejected")}`,
    `batches deferred by 503: ${count(data, "batches_deferred")}, answered as duplicate: ${count(data, "batches_duplicate")}, abandoned: ${count(data, "batches_abandoned")}`,
  ];

  return { stdout: `\n${lines.join("\n")}\n` };
}
