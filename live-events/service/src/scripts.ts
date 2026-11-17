export const CREATE = `
if redis.call('EXISTS', KEYS[1]) == 1 then
  return redis.call('HGET', KEYS[1], 'spec')
end
redis.call('HSET', KEYS[1], 'state', 'live', 'created_at', ARGV[1], 'ends_at', ARGV[2],
  'goal_option', ARGV[3], 'goal_target', ARGV[4], 'completed_at', '', 'spec', ARGV[5], 'shards', ARGV[6])
for i = 7, #ARGV do
  redis.call('SADD', KEYS[2], ARGV[i])
end
return false
`;

export const VIEW = `
local meta = redis.call('HMGET', KEYS[1], 'state', 'ends_at', 'goal_option', 'goal_target', 'completed_at', 'shards')
if not meta[1] then
  return false
end
return {meta[1], meta[2], meta[3], meta[4], meta[5], meta[6] or '1', redis.call('SMEMBERS', KEYS[2])}
`;

export const COMPLETE = `
local state = redis.call('HGET', KEYS[1], 'state')
if state == 'live' then
  redis.call('HSET', KEYS[1], 'state', 'completed', 'completed_at', ARGV[1])
  return {'completed', ARGV[1]}
end
return {state or '', redis.call('HGET', KEYS[1], 'completed_at') or ''}
`;

export const PUBLISH_SHARD = `
local entries, totals, seen, version = KEYS[1], KEYS[2], KEYS[3], KEYS[4]
local now = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local closed = ARGV[3] == '1'
local option_count = tonumber(ARGV[4])
local allowed = {}
for i = 5, 4 + option_count do
  allowed[ARGV[i]] = true
end

local count = tonumber(ARGV[5 + option_count])
local i = 6 + option_count
local ignored = 0
local changed = false
for _ = 1, count do
  local server = ARGV[i]
  local fields = tonumber(ARGV[i + 1])
  i = i + 2
  if not closed and server ~= '' then
    redis.call('ZADD', seen, now, server)
  end

  for _ = 1, fields do
    local sign, option, value = ARGV[i], ARGV[i + 1], tonumber(ARGV[i + 2])
    i = i + 3
    if not closed then
      if allowed[option] then
        local field = sign .. '|' .. server .. '|' .. option
        local current = tonumber(redis.call('HGET', entries, field) or '0')
        if value > current then
          redis.call('HSET', entries, field, value)
          local delta = value - current
          if sign == 'm' then
            delta = -delta
          end
          redis.call('HINCRBY', totals, option, delta)
          changed = true
        end
      else
        ignored = ignored + 1
      end
    end
  end
end

local current
if changed then
  current = redis.call('INCR', version)
else
  current = tonumber(redis.call('GET', version) or '0')
end
redis.call('ZREMRANGEBYSCORE', seen, '-inf', '(' .. (now - window))
return {current, redis.call('ZCARD', seen), ignored, redis.call('HGETALL', totals)}
`;

export const READ_SHARD = `
local now = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
return {tonumber(redis.call('GET', KEYS[4]) or '0'), redis.call('ZCOUNT', KEYS[3], now - window, '+inf'), 0,
  redis.call('HGETALL', KEYS[2])}
`;
