CREATE DATABASE IF NOT EXISTS analytics;

CREATE TABLE IF NOT EXISTS analytics.events
(
    at DateTime64(3, 'UTC'),
    received_at DateTime64(3, 'UTC'),
    name LowCardinality(String),
    server_id String,
    place_id UInt64,
    place_version UInt32,
    user_id UInt64,
    session_id String,
    weight Float32,
    props String
)
ENGINE = MergeTree
PARTITION BY toDate(at)
ORDER BY (name, at)
TTL toDateTime(at) + INTERVAL 90 DAY
SETTINGS non_replicated_deduplication_window = 10000;

CREATE TABLE IF NOT EXISTS analytics.events_per_minute
(
    minute DateTime('UTC'),
    name LowCardinality(String),
    event_count SimpleAggregateFunction(sum, UInt64),
    weighted_count SimpleAggregateFunction(sum, Float64),
    users AggregateFunction(uniq, UInt64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(minute)
ORDER BY (minute, name)
TTL minute + INTERVAL 90 DAY;

CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.events_per_minute_mv
TO analytics.events_per_minute
AS SELECT
    toStartOfMinute(toDateTime(at, 'UTC')) AS minute,
    name,
    count() AS event_count,
    sum(weight) AS weighted_count,
    uniqStateIf(user_id, user_id != 0) AS users
FROM analytics.events
GROUP BY minute, name;
