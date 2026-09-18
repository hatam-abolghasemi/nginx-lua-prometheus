-- app_toggle.lua
-- Per-app / per-destination metrics enable switch, so one leg of traffic
-- (e.g. the forward-proxy leg, or a single stream destination) can have its
-- metrics turned off while the traffic itself keeps flowing unaffected.
--
-- An app with no explicit `metrics_enabled` entry -- or no entry at all --
-- defaults to enabled. This is opt-out, not opt-in: adding a new app/
-- destination should never silently produce metrics that were forgotten
-- about, but it should also never require touching this table just to keep
-- getting metrics for it.
--
-- Pure Lua, no ngx.* dependency.
--
-- Usage:
--   local app_toggle = require("app_toggle")
--   local apps = {
--     forward_proxy = { metrics_enabled = false },
--   }
--   app_toggle.enabled(apps, "forward_proxy")   --> false
--   app_toggle.enabled(apps, "some_other_leg")  --> true (no entry = enabled)

local _M = {}

-- key may be nil (e.g. a stream destination that hasn't been set yet); that
-- always reads as enabled rather than erroring, since a request with no
-- identifiable app/destination shouldn't be silently dropped from metrics.
function _M.enabled(apps, key)
  if not apps or not key then
    return true
  end
  local app_cfg = apps[key]
  if app_cfg == nil then
    return true
  end
  return app_cfg.metrics_enabled ~= false
end

return _M
