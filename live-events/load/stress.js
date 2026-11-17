import http from "k6/http";
import { check } from "k6";
import { Counter, Gauge } from "k6/metrics";

const URL = __ENV.EVENTS_URL || "http://events:8080";
const RATE = Number(__ENV.RATE || 2000);
const DURATION = __ENV.DURATION || "45s";
const EVENTS = Number(__ENV.EVENTS || 1);
const VUS = Number(__ENV.VUS || Math.max(50, Math.ceil(RATE / 20)));
const RUN = Date.now().toString(36);
const FISH_PER_FLUSH_MAX = 40;

const contributed = new Counter("fish_contributed");
const finalTotal = new Gauge("fish_final_total");

const server = { headers: { "Content-Type": "application/json", Authorization: `Bearer ${__ENV.EVENTS_SERVER_TOKEN}` } };
const admin = { headers: { "Content-Type": "application/json", Authorization: `Bearer ${__ENV.EVENTS_ADMIN_TOKEN}` } };

export const options = {
  discardResponseBodies: false,
  scenarios: {
    publishers: {
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
    "http_req_duration{name:publish}": ["p(95)<100", "p(99)<250"],
    "http_reqs{name:publish}": ["count>0"],
  },
};

function eventIds() {
  return Array.from({ length: EVENTS }, (_, i) => `stress_${RUN}_${i}`);
}

export function setup() {
  for (const id of eventIds()) {
    const response = http.put(`${URL}/v1/events/${id}`, JSON.stringify({ options: ["fish"] }), admin);
    check(response, { "event created": (r) => r.status === 201 || r.status === 200 });
  }

  return { events: eventIds() };
}

const servers = new Map();

export default function (data) {
  const slot = `${__VU}-${__ITER % 64}`;
  const previous = servers.get(slot) || 0;
  const delta = Math.floor(Math.random() * FISH_PER_FLUSH_MAX);
  const cumulative = previous + delta;
  const events = {};
  for (const id of data.events) {
    events[id] = { plus: { fish: cumulative } };
  }

  const body = JSON.stringify({ server: `s-${RUN}-${slot}`, events });
  const response = http.post(`${URL}/v1/publish`, body, Object.assign({ tags: { name: "publish" } }, server));
  if (check(response, { "publish ok": (r) => r.status === 200 })) {
    servers.set(slot, cumulative);
    contributed.add(delta);
  }
}

export function teardown(data) {
  let total = 0;
  for (const id of data.events) {
    const response = http.get(`${URL}/v1/events/${id}`, server);
    total += response.json("totals.fish") || 0;
  }

  finalTotal.add(total / data.events.length);
}

export function handleSummary(data) {
  const sent = data.metrics.fish_contributed ? data.metrics.fish_contributed.values.count : 0;
  const total = data.metrics.fish_final_total ? data.metrics.fish_final_total.values.value : 0;
  const publish = data.metrics["http_req_duration{name:publish}"] || data.metrics.http_req_duration;
  const requests = data.metrics["http_reqs{name:publish}"] || data.metrics.http_reqs;
  const dropped = data.metrics.dropped_iterations ? data.metrics.dropped_iterations.values.count : 0;
  const seconds = data.state.testRunDurationMs / 1000;
  const lines = [
    `target ${RATE} publishes/s for ${DURATION}, ${EVENTS} event(s) per publish`,
    `publishes: ${requests.values.count} (${(requests.values.count / seconds).toFixed(0)}/s), dropped by k6: ${dropped}`,
    `publish latency p50 ${publish.values.med.toFixed(1)} ms, p95 ${publish.values["p(95)"].toFixed(1)} ms, p99 ${publish.values["p(99)"].toFixed(1)} ms, max ${publish.values.max.toFixed(1)} ms`,
    `failed: ${(data.metrics.http_req_failed.values.rate * 100).toFixed(3)}%`,
    `fish acknowledged per event: ${sent}, stored per event: ${total}, ${sent === total ? "EXACT" : "MISMATCH"}`,
  ];

  return { stdout: `\n${lines.join("\n")}\n` };
}
