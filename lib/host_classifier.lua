-- host_classifier.lua
-- Collapses the Host header into a bounded set of label values instead of
-- passing raw pod/service IPs through, which would create one time series
-- per address that ever touched a Host header.
--
-- Pure Lua, no ngx.* dependency.
--
-- Usage:
--   local host_classifier = require("host_classifier")
--   host_classifier.classify("10.233.4.12", "10.233.")  --> "kubernetes"
--   host_classifier.classify("api.example.com", "10.233.") --> "api.example.com"

local _M = {}

-- cluster_ip_prefix: a string prefix (e.g. "10.233.") identifying your
-- cluster's internal pod/service CIDR. IPs starting with this prefix are
-- classified as "kubernetes"; any other IP literal (v4 or v6-shaped) becomes
-- "$ip". Real domain names pass through unchanged.
function _M.classify(host, cluster_ip_prefix)
  if not host then return host end

  local hostpart = host:match("^([^:]+):?%d*$") or host

  if hostpart == "127.0.0.1" or hostpart == "localhost" then
    return "localhost"
  end

  if hostpart:match("^%d+%.%d+%.%d+%.%d+$") then
    if cluster_ip_prefix and hostpart:sub(1, #cluster_ip_prefix) == cluster_ip_prefix then
      return "kubernetes"
    end
    return "$ip"
  end

  -- loose IPv6 literal check
  if hostpart:match("^[%x:]+$") and hostpart:find(":") then
    return "$ip"
  end

  return host
end

return _M
