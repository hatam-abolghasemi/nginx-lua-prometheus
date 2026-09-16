-- client_subnet.lua
-- Masks a client IPv4 address down to a /24 (private ranges) or /16 (public
-- ranges) so it's safe to use as a Prometheus label without one time series
-- per client address. IPv6 and unparseable input return "unknown".
--
-- Pure Lua, no ngx.* dependency.
--
-- Usage:
--   local client_subnet = require("client_subnet")
--   client_subnet.mask("10.233.4.17")     --> "10.233.4.0"
--   client_subnet.mask("8.8.8.8")         --> "8.8.0.0"
--   client_subnet.mask("10.1.2.3, 8.8.8.8") --> "10.1.2.0" (first address wins)

local _M = {}

function _M.mask(addr)
  if not addr then return "unknown" end

  -- if a comma-separated list (e.g. X-Forwarded-For), take the first entry
  local ip = addr:match("^%s*([^,]+)"):match("^%s*(.-)%s*$")

  local a, b, c = ip:match("^(%d+)%.(%d+)%.(%d+)%.%d+$")
  if not a then return "unknown" end
  a, b, c = tonumber(a), tonumber(b), tonumber(c)

  -- RFC1918 / typical pod CIDRs: keep /24 for locality
  if a == 10 or a == 192 or (a == 172 and b >= 16 and b <= 31) then
    return a .. "." .. b .. "." .. c .. ".0"
  end

  -- public IPs: /16 is enough, avoids high cardinality
  return a .. "." .. b .. ".0.0"
end

return _M
