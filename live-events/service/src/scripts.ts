export const CREATE = `
if redis.call('EXISTS', KEYS[1]) == 1 then
  return redis.call('HGET', KEYS[1], 'spec')
end
redis.call('HSET', KEYS[1], 'state', 'live', 'version', 0, 'created_at', ARGV[1], 'ends_at', ARGV[2],
  'goal_option', ARGV[3], 'goal_target', ARGV[4], 'completed_at', '', 'spec', ARGV[5])
for i = 6, #ARGV do
  redis.call('SADD', KEYS[2], ARGV[i])
end
return false
`;

export const PUBLISH = `
local meta, options, entries, totals, seen = KEYS[1], KEYS[2], KEYS[3], KEYS[4], KEYS[5]
local state = redis.call('HGET', meta, 'state')
if not state then
  return false
end

local now = tonumber(ARGV[1])
local grace = tonumber(ARGV[2])
local window = tonumber(ARGV[3])
local count = tonumber(ARGV[4])
local ends_at = tonumber(redis.call('HGET', meta, 'ends_at'))

if state ~= 'closed' and ends_at > 0 and now >= ends_at + grace then
  redis.call('HSET', meta, 'state', 'closed')
  state = 'closed'
end

local ignored = 0
local changed = false
local i = 5
for _ = 1, count do
  local server = ARGV[i]
  local fields = tonumber(ARGV[i + 1])
  i = i + 2
  if state ~= 'closed' and server ~= '' then
    redis.call('ZADD', seen, now, server)
  end

  for _ = 1, fields do
    local sign, option, value = ARGV[i], ARGV[i + 1], tonumber(ARGV[i + 2])
    i = i + 3
    if state ~= 'closed' then
      if redis.call('SISMEMBER', options, option) == 1 then
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

if changed then
  redis.call('HINCRBY', meta, 'version', 1)
  local goal_option = redis.call('HGET', meta, 'goal_option')
  if state == 'live' and goal_option ~= '' then
    local reached = tonumber(redis.call('HGET', totals, goal_option) or '0')
    if reached >= tonumber(redis.call('HGET', meta, 'goal_target')) then
      redis.call('HSET', meta, 'state', 'completed', 'completed_at', now)
      state = 'completed'
    end
  end
end

local active = redis.call('ZCOUNT', seen, now - window, '+inf')
return {state, redis.call('HGET', meta, 'version'), redis.call('HGET', meta, 'completed_at'), ends_at, active,
  ignored, redis.call('HGETALL', totals)}
`;
