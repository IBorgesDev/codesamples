export const APPEND_BATCH = `
if redis.call('EXISTS', KEYS[1]) == 1 then
  return 0
end
if ARGV[2] ~= '' then
  redis.call('XADD', KEYS[2], '*', 'batch', ARGV[2])
end
redis.call('SET', KEYS[1], '1', 'EX', ARGV[1])
return 1
`;
