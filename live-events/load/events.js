import http from "k6/http";
import { check, sleep } from "k6";
import { Counter, Gauge } from "k6/metrics";

const URL = __ENV.EVENTS_URL || "http://events:8080";
const SERVERS = Number(__ENV.SERVERS || 2000);
const FLUSH_SECONDS = Number(__ENV.FLUSH_SECONDS || 2);
const DURATION = __ENV.DURATION || "2m";
const EVENT = `load_${Date.now()}`;
const FISH_PER_FLUSH_MAX = 40;

const contributed = new Counter("fish_contributed");
const finalTotal = new Gauge("fish_final_total");

const server = { headers: { "Content-Type": "application/json", Authorization: `Bearer ${__ENV.EVENTS_SERVER_TOKEN}` } };
const admin = { headers: { "Content-Type": "application/json", Authorization: `Bearer ${__ENV.EVENTS_ADMIN_TOKEN}` } };

export const options = {
  scenarios: {
    servers: {
      executor: "constant-vus",
      vus: SERVERS,
      duration: DURATION,
      gracefulStop: "10s",
    },
  },
  summaryTrendStats: ["avg", "min", "med", "max", "p(95)", "p(99)"],
  thresholds: {
    http_req_failed: ["rate<0.001"],
    "http_req_duration{name:publish}": ["p(95)<100", "p(99)<250"],
  },
};

export function setup() {
  const response = http.put(`${URL}/v1/events/${EVENT}`, JSON.stringify({ options: ["fish"] }), admin);
  check(response, { "event created": (r) => r.status === 201 || r.status === 200 });
  return { event: EVENT };
}

let cumulative = 0;

export default function (data) {
  const delta = Math.floor(Math.random() * FISH_PER_FLUSH_MAX);
  cumulative += delta;
  const body = JSON.stringify({ server: `vu-${__VU}`, events: { [data.event]: { plus: { fish: cumulative } } } });
  let response = http.post(`${URL}/v1/publish`, body, Object.assign({ tags: { name: "publish" } }, server));
  for (let attempt = 0; attempt < 3 && response.status !== 200; attempt++) {
    sleep(0.2 * (attempt + 1));
    response = http.post(`${URL}/v1/publish`, body, Object.assign({ tags: { name: "publish" } }, server));
  }

  if (check(response, { "publish ok": (r) => r.status === 200 })) {
    contributed.add(delta);
  }

  sleep(FLUSH_SECONDS * (0.75 + Math.random() * 0.5));
}

export function teardown(data) {
  const response = http.get(`${URL}/v1/events/${data.event}`, server);
  finalTotal.add(response.json("totals.fish") || 0);
}

export function handleSummary(data) {
  const sent = data.metrics.fish_contributed ? data.metrics.fish_contributed.values.count : 0;
  const total = data.metrics.fish_final_total ? data.metrics.fish_final_total.values.value : 0;
  const publish = data.metrics["http_req_duration{name:publish}"] || data.metrics.http_req_duration;
  const requests = data.metrics.http_reqs.values;
  const lines = [
    `servers (VUs): ${SERVERS}, flush every ~${FLUSH_SECONDS}s, ${DURATION}`,
    `requests: ${requests.count} (${requests.rate.toFixed(0)}/s)`,
    `publish latency p50 ${publish.values.med.toFixed(1)} ms, p95 ${publish.values["p(95)"].toFixed(1)} ms, p99 ${publish.values["p(99)"].toFixed(1)} ms, max ${publish.values.max.toFixed(1)} ms`,
    `failed: ${(data.metrics.http_req_failed.values.rate * 100).toFixed(3)}%`,
    `fish acknowledged by clients: ${sent}, total stored: ${total}, ${sent === total ? "EXACT" : "MISMATCH"}`,
  ];

  return { stdout: `\n${lines.join("\n")}\n` };
}
