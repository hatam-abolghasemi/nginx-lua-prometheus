-- source_attribution.lua
-- Identifies the calling service/namespace behind an inbound request, so
-- "who is calling this" is a queryable Prometheus label instead of
-- something you cross-reference from access logs by hand.
--
-- Resolution order:
--   1. classify_static() -- cheap, no-DNS classification for known static
--      ranges (e.g. a fixed internal VLAN), and a fast "public" bucket for
--      anything clearly external.
--   2. For addresses in a configured dynamic range (e.g. a Kubernetes pod
--      CIDR, too fast-churning for a static table), a reverse-DNS (PTR)
--      lookup against your cluster DNS, cached in a shared dict.
--   3. apply_waypoint_override() -- if the resolved caller turns out to BE
--      a known service-mesh waypoint, recovers the real original caller's
--      identity from a verified X-Forwarded-Client-Cert (XFCC) header
--      instead of attributing the request to the waypoint itself.
--
-- classify_static, parse_ptr, and parse_xfcc are pure functions with no
-- ngx.* dependency and are fully unit-tested. The stateful Resolver (DNS
-- query, shared-dict caching, in-flight locking) takes its shared dict and
-- DNS resolver library as injectable dependencies specifically so it can
-- be exercised in tests with fakes, without needing a real nginx worker
-- or real DNS traffic.
--
-- Usage (inside init_worker_by_lua_block):
--   local source_attribution = require("source_attribution")
--   local resolver = source_attribution.new_resolver{
--     dict = ngx.shared.ptr_cache,
--     cache_ttl = 15,
--     dns = { nameservers = {{"10.233.0.3", 53}}, timeout_ms = 200 },
--     static_ranges = {
--       { prefix = {192, 168}, label = "internal", zone_map = {[10] = "zone_a"} },
--     },
--     dynamic_prefix = {10, 233},
--     default_service = "unknown-caller",
--     default_namespace = "unknown",
--   }
--
-- ...and per-request (e.g. in access_by_lua_block):
--   local service, namespace = resolver:resolve(ngx.var.remote_addr)
--   service, namespace = source_attribution.apply_waypoint_override(
--     service, namespace, ngx.var.http_x_forwarded_client_cert, "waypoint")

local _M = {}

-- ---------------------------------------------------------------------
-- Pure functions
-- ---------------------------------------------------------------------

-- Classifies an IPv4 address using only static configuration -- no DNS.
-- Returns service, namespace when a static classification applies.
-- Returns nil when the address falls in `cfg.dynamic_prefix` and should be
-- resolved via PTR instead (see Resolver:resolve below).
--
-- cfg = {
--   dynamic_prefix = {a, b},      -- e.g. {10, 233}: defer these to PTR
--   static_ranges = {             -- checked in order, first match wins
--     { prefix = {a, b}, label = "internal", zone_map = {[c] = "zone_name"}, default_zone = "unknown" },
--   },
--   default_label = "public",
--   default_namespace = "unknown",
-- }
function _M.classify_static(ip, cfg)
  cfg = cfg or {}
  local a, b, c = ip:match("^(%d+)%.(%d+)%.(%d+)%.%d+$")
  if not a then
    return cfg.default_label or "public", cfg.default_namespace or "unknown"
  end
  a, b, c = tonumber(a), tonumber(b), tonumber(c)

  if cfg.dynamic_prefix and a == cfg.dynamic_prefix[1] and b == cfg.dynamic_prefix[2] then
    return nil -- caller should resolve this one via PTR
  end

  for _, range in ipairs(cfg.static_ranges or {}) do
    if a == range.prefix[1] and b == range.prefix[2] then
      local zone = (range.zone_map and range.zone_map[c]) or range.default_zone or "unknown"
      return range.label, zone
    end
  end

  return cfg.default_label or "public", cfg.default_namespace or "unknown"
end

-- Parses a PTR record's target name into service, namespace.
-- Recognizes two Kubernetes cluster-DNS shapes:
--   <pod>.<service>.<namespace>.svc.cluster.local.  -> service, namespace
--   <pod>.<namespace>.pod.cluster.local.             -> nil, namespace
-- Returns nil, nil if the name matches neither shape.
function _M.parse_ptr(ptrdname)
  if not ptrdname then return nil, nil end
  local svc, ns = ptrdname:match("^[%d%-]+%.([^%.]+)%.([^%.]+)%.svc%.cluster%.local%.?$")
  if svc then return svc, ns end
  local pod_ns = ptrdname:match("^[%d%-]+%.([^%.]+)%.pod%.cluster%.local%.?$")
  if pod_ns then return nil, pod_ns end
  return nil, nil
end

-- Parses the SPIFFE URI out of an X-Forwarded-Client-Cert header value.
-- Returns namespace, service_account, or nil, nil if not present/malformed.
-- Expected shape: URI=spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>
function _M.parse_xfcc(header)
  if not header then return nil, nil end
  local ns, sa = header:match("URI=spiffe://[^/]+/ns/([^/]+)/sa/([^;,]+)")
  return ns, sa
end

-- If `service` is the known mesh waypoint, recovers the real caller's
-- identity from the XFCC header instead. Otherwise returns service,
-- namespace unchanged.
--
-- Security note: only call this after `service` has already been derived
-- from an independently verified source (e.g. Resolver:resolve, which is
-- PTR-based). Trusting an XFCC header without first confirming the direct
-- peer really is the waypoint would let any caller spoof their reported
-- identity by setting that header themselves.
function _M.apply_waypoint_override(service, namespace, xfcc_header, waypoint_service_name)
  if service ~= waypoint_service_name then
    return service, namespace
  end
  local ns, sa = _M.parse_xfcc(xfcc_header)
  if ns and sa then
    return sa, ns
  end
  return service, namespace
end

-- ---------------------------------------------------------------------
-- Stateful resolver (DNS + cache). Dependencies are injectable for testing.
-- ---------------------------------------------------------------------

local Resolver = {}
Resolver.__index = Resolver

-- opts = {
--   dict           = <shared dict for PTR result caching>,
--   cache_ttl      = seconds successful PTR results are cached for,
--   dns            = { nameservers = {{ip, port}}, timeout_ms, retrans },
--   static_ranges / dynamic_prefix / default_label / default_namespace
--                  = passed through to classify_static,
--   default_service = fallback service name when PTR resolution doesn't
--                     complete (timeout, no record, in-flight elsewhere),
--   resolver_lib   = the resty.dns.resolver module (or a test double with
--                    the same .new()/:query()/.TYPE_PTR shape). Defaults
--                    to require("resty.dns.resolver") when omitted.
-- }
function _M.new_resolver(opts)
  assert(opts and opts.dict, "source_attribution.new_resolver requires opts.dict")
  local self = setmetatable({}, Resolver)
  self.dict = opts.dict
  self.cache_ttl = opts.cache_ttl or 15
  self.dns = opts.dns or {}
  self.static_cfg = {
    dynamic_prefix    = opts.dynamic_prefix,
    static_ranges     = opts.static_ranges,
    default_label     = opts.default_label,
    default_namespace = opts.default_namespace,
  }
  self.default_service = opts.default_service or "unknown-caller"
  self.default_namespace = opts.default_namespace or "unknown"
  self.resolver_lib = opts.resolver_lib
  return self
end

local function ptr_query_name(ip)
  local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  return d .. "." .. c .. "." .. b .. "." .. a .. ".in-addr.arpa"
end

-- Resolves an IP to service, namespace. Order: static classification, then
-- cache, then (with an in-flight lock to avoid duplicate concurrent
-- queries for the same uncached IP) a live PTR lookup, caching the result.
-- Falls back to default_service/default_namespace whenever resolution
-- doesn't complete synchronously.
function Resolver:resolve(ip)
  if not ip then
    return self.default_service, self.default_namespace
  end

  local static_svc, static_ns = _M.classify_static(ip, self.static_cfg)
  if static_svc then
    return static_svc, static_ns
  end

  local cached = self.dict:get(ip)
  if cached then
    local svc, ns = cached:match("^([^|]*)|(.*)$")
    return svc, ns
  end

  local inflight_key = "inflight:" .. ip
  if self.dict:get(inflight_key) then
    -- someone else is already resolving this IP; don't pile on more
    -- concurrent DNS queries for it
    return self.default_service, self.default_namespace
  end

  local locked = self.dict:add(inflight_key, true, (self.dns.timeout_ms or 200) / 1000 + 1)
  if not locked then
    return self.default_service, self.default_namespace
  end

  local resolver_lib = self.resolver_lib
  if not resolver_lib then
    resolver_lib = require("resty.dns.resolver")
  end

  local svc, ns = self.default_service, self.default_namespace
  local query_name = ptr_query_name(ip)
  if query_name then
    local r = resolver_lib:new{
      nameservers = self.dns.nameservers,
      retrans     = self.dns.retrans or 1,
      timeout     = self.dns.timeout_ms or 200,
    }
    if r then
      -- resty.dns.resolver's :query() returns (answers, err), not a
      -- separate ok flag; pcall prepends its own success flag ahead of
      -- those two return values.
      local pcall_ok, answers = pcall(r.query, r, query_name, { qtype = resolver_lib.TYPE_PTR })
      local ptrdname = pcall_ok and answers and answers[1] and answers[1].ptrdname
      if ptrdname then
        local parsed_svc, parsed_ns = _M.parse_ptr(ptrdname)
        svc = parsed_svc or svc
        ns = parsed_ns or ns
      end
    end
  end

  self.dict:set(ip, svc .. "|" .. ns, self.cache_ttl)
  return svc, ns
end

-- PTR-only lookup: no static classification, no shared-dict cache or
-- in-flight lock. Returns service, namespace when the PTR record names a
-- Service (<pod>.<service>.<namespace>.svc.cluster.local.), otherwise nil --
-- i.e. it never substitutes defaults, so a caller can tell "resolved" from
-- "didn't resolve". Used by self_identity.lua to discover this pod's own
-- Service; the per-request path stays on Resolver:resolve above.
function Resolver:resolve_ptr(ip)
  local query_name = ip and ptr_query_name(ip)
  if not query_name then return nil end

  local resolver_lib = self.resolver_lib or require("resty.dns.resolver")
  local r = resolver_lib:new{
    nameservers = self.dns.nameservers,
    retrans     = self.dns.retrans or 1,
    timeout     = self.dns.timeout_ms or 200,
  }
  if not r then return nil end

  local pcall_ok, answers = pcall(r.query, r, query_name, { qtype = resolver_lib.TYPE_PTR })
  local ptrdname = pcall_ok and answers and answers[1] and answers[1].ptrdname
  if not ptrdname then return nil end

  local svc, ns = _M.parse_ptr(ptrdname)
  if svc and ns then return svc, ns end
  return nil
end

return _M
