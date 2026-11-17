import { Counter, Histogram, Registry, collectDefaultMetrics } from "prom-client";

export const registry = new Registry();

collectDefaultMetrics({ register: registry });

export const requestSeconds = new Histogram({
  name: "events_request_seconds",
  help: "Request latency by route and status",
  labelNames: ["route", "status"],
  buckets: [0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1],
  registers: [registry],
});

export const publishedEvents = new Counter({
  name: "events_published_total",
  help: "Event contributions received, by result",
  labelNames: ["result"],
  registers: [registry],
});

export const ignoredOptions = new Counter({
  name: "events_ignored_options_total",
  help: "Contributions to options the event does not have",
  registers: [registry],
});
