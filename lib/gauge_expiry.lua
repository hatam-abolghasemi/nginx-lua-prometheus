-- gauge_expiry.lua
-- Tracks "last updated" timestamps for gauge metrics keyed by an arbitrary
-- scope (e.g. "req", "conn") and label values, and periodically sweeps for
-- entries that have gone quiet longer than a configured window -- calling
-- back so the caller can zero the corresponding gauge(s).
--
-- This exists because Prometheus gauges do not self-expire: a gauge set
-- once and never updated again reports that stale value forever, which is
-- actively misleading for a low-traffic label combination.
--
-- The key-encoding and sweep logic (encode_key/decode_key/sweep) are pure
-- and unit-testable against any dict-like object exposing get/set/delete/
-- get_keys. Only :start() requires a real nginx worker (ngx.timer.at).
--
-- Usage (inside init_worker_by_lua_block):
--   local gauge_expiry = require("gauge_expiry")
--   local expiry = gauge_expiry.new{ dict = ngx.shared.custom_metrics, window = 10, scan_limit = 10000 }
--   expiry:start(5, function(scope, labels)
--     if scope == "req" then
--       metric_latency:set(0, labels)
--       metric_request_size:set(0, labels)
--     elseif scope == "conn" then
--       metric_connection_requests:set(0, labels)
--     end
--   end)
--
-- ...and in log_by_lua_block, after setting the live gauge values:
--   expiry:touch("req", labels)

local _M = {}
_M.__index = _M

function _M.new(opts)
  assert(opts and opts.dict, "gauge_expiry.new requires opts.dict")
  local self = setmetatable({}, _M)
  self.dict = opts.dict
  self.window = opts.window or 10
  self.scan_limit = opts.scan_limit or 1000
  return self
end

-- Encodes a tracking key from a scope name and an ordered array of label
-- values. Label values must not themselves contain the "|" separator.
function _M.encode_key(scope, label_values)
  return scope .. "|" .. table.concat(label_values, "|")
end

-- Decodes a tracking key back into its scope and ordered label values.
function _M.decode_key(key)
  local parts = {}
  for part in key:gmatch("[^|]+") do
    table.insert(parts, part)
  end
  local scope = parts[1]
  local labels = {}
  for i = 2, #parts do
    table.insert(labels, parts[i])
  end
  return scope, labels
end

-- Records that the metric(s) under `scope` with `label_values` were just
-- updated. Call this once per scope per request, immediately after setting
-- the live gauge value(s) that scope covers.
function _M:touch(scope, label_values, now)
  now = now or (ngx and ngx.now())
  assert(now, "gauge_expiry:touch requires `now` outside of an ngx worker")
  self.dict:set(_M.encode_key(scope, label_values), tostring(now))
end

-- Scans up to `scan_limit` tracked keys. For each whose last touch is older
-- than `window` seconds relative to `now`, calls on_expire(scope, labels)
-- and then removes the tracking key. Returns the number of keys expired.
function _M:sweep(now, on_expire)
  now = now or (ngx and ngx.now())
  assert(now, "gauge_expiry:sweep requires `now` outside of an ngx worker")

  local expired_count = 0
  local keys = self.dict:get_keys(self.scan_limit)
  for _, key in ipairs(keys) do
    local raw = self.dict:get(key)
    local last_update = raw and tonumber(raw)
    if last_update and (now - last_update) > self.window then
      local scope, labels = _M.decode_key(key)
      on_expire(scope, labels)
      self.dict:delete(key)
      expired_count = expired_count + 1
    end
  end
  return expired_count
end

-- Starts a recurring ngx.timer.at loop calling sweep() every `interval`
-- seconds, forwarding expirations to on_expire(scope, labels). Must be
-- called from within an nginx worker (e.g. init_worker_by_lua_block).
function _M:start(interval, on_expire)
  local self_ref = self
  local function tick(premature)
    if premature then return end
    local ok, err = pcall(function() self_ref:sweep(nil, on_expire) end)
    if not ok then
      ngx.log(ngx.ERR, "gauge_expiry: sweep failed: ", err)
    end
    local resched_ok, resched_err = ngx.timer.at(interval, tick)
    if not resched_ok then
      ngx.log(ngx.ERR, "gauge_expiry: failed to reschedule: ", resched_err)
    end
  end
  local ok, err = ngx.timer.at(interval, tick)
  if not ok then
    ngx.log(ngx.ERR, "gauge_expiry: failed to start: ", err)
  end
end

return _M
