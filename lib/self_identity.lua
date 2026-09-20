-- self_identity.lua
-- Discovers *this* pod's own service/namespace instead of hard-coding it in
-- metrics_config.lua, using the same reverse-DNS (PTR) mechanism
-- source_attribution.lua uses to identify callers. The two therefore always
-- agree: the name other pods see for this pod as `source_service` is the name
-- this pod reports for itself.
--
-- Why it exists: a config file that's shared by several Deployments (one
-- ConfigMap mounted into app, consumers, cronjob, ...) can only hold one
-- hard-coded `app` value, so every pod reported itself as that one service.
--
-- How it works:
--   1. Find the pod's own IPv4: kubelet writes `<pod-ip>  <pod-hostname>` into
--      /etc/hosts, and the container's hostname is the pod name.
--   2. PTR-resolve that IP (resolver:resolve_ptr) -> <service>.<namespace>.
--   3. Until that succeeds, get() returns the configured fallback. A pod only
--      has a PTR record once it is a Ready endpoint of a Service, so this is
--      retried in a timer (with backoff) rather than attempted once at boot.
--
-- Pure pieces (pod_ip_from_hosts, refresh) take their file reader and
-- resolver as injectable dependencies so they're testable without nginx.
--
-- Usage (inside init_worker_by_lua_block, after building the resolver):
--   local self_identity = require("self_identity")
--   local ident = self_identity.new{
--     resolver           = resolver,          -- a source_attribution resolver
--     fallback_service   = "example-app",
--     fallback_namespace = "example-namespace",
--     on_change          = function(old_svc, old_ns, new_svc, new_ns) ... end, -- optional
--   }
--   ident:start()
--   -- anywhere later (any phase, no cosockets needed):
--   local service, namespace = ident:get()

local _M = {}
_M.__index = _M

-- Returns the IPv4 address /etc/hosts maps to `hostname`, or nil. Loopback
-- entries (127.x) are skipped: HostAliases and `localhost` lines are not the
-- pod's own address. Pure.
function _M.pod_ip_from_hosts(content, hostname)
  if not content or not hostname or hostname == "" then return nil end
  for raw in content:gmatch("[^\r\n]+") do
    local line = raw:gsub("#.*$", "")
    local ip, rest = line:match("^%s*(%d+%.%d+%.%d+%.%d+)%s+(.+)$")
    if ip and not ip:match("^127%.") then
      for name in rest:gmatch("%S+") do
        if name == hostname then return ip end
      end
    end
  end
  return nil
end

local function default_read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

-- opts = {
--   resolver           = source_attribution resolver (needs :resolve_ptr),
--   fallback_service   = value get() returns until resolved,
--   fallback_namespace = ditto,
--   on_change          = optional function(old_svc, old_ns, new_svc, new_ns),
--   interval           = first retry delay in seconds (default 5),
--   max_interval       = backoff ceiling in seconds (default 60),
--   read_file          = function(path) -> string|nil   (injectable for tests),
--   hostname           = override for the container hostname (tests),
-- }
function _M.new(opts)
  assert(opts and opts.resolver, "self_identity.new requires opts.resolver")
  local self = setmetatable({}, _M)
  self.resolver           = opts.resolver
  self.service            = opts.fallback_service
  self.namespace          = opts.fallback_namespace
  self.on_change          = opts.on_change
  self.interval           = opts.interval or 5
  self.max_interval       = opts.max_interval or 60
  self.read_file          = opts.read_file or default_read_file
  self.hostname           = opts.hostname
  self.resolved           = false
  return self
end

-- Current identity. Safe in every phase (no I/O, no cosockets).
function _M:get()
  return self.service, self.namespace
end

function _M:is_resolved()
  return self.resolved
end

local function trim(s) return s and s:match("^%s*(.-)%s*$") end

function _M:find_ip()
  local hostname = self.hostname
    or trim(self.read_file("/proc/sys/kernel/hostname"))
    or trim(self.read_file("/etc/hostname"))
  return _M.pod_ip_from_hosts(self.read_file("/etc/hosts"), hostname)
end

-- One resolution attempt. Returns true once an identity has been resolved.
-- Needs cosockets (it does DNS), so call it from a timer or access phase, not
-- init_worker / log.
function _M:refresh()
  local ip = self.ip or self:find_ip()
  if not ip then return false end
  self.ip = ip

  local svc, ns = self.resolver:resolve_ptr(ip)
  if not svc then return false end

  local old_svc, old_ns = self.service, self.namespace
  self.service, self.namespace, self.resolved = svc, ns, true
  if self.on_change and (old_svc ~= svc or old_ns ~= ns) then
    self.on_change(old_svc, old_ns, svc, ns)
  end
  return true
end

-- Starts the retry loop; stops once resolved. Backs off exponentially so a pod
-- that never becomes a Service endpoint doesn't hammer cluster DNS.
function _M:start()
  local delay = self.interval
  local function tick(premature)
    if premature then return end
    local ok, resolved = pcall(self.refresh, self)
    if not ok then
      ngx.log(ngx.ERR, "self_identity: refresh failed: ", resolved)
    elseif resolved then
      ngx.log(ngx.NOTICE, "self_identity: resolved ", tostring(self.service),
              "/", tostring(self.namespace))
      return
    end
    local sched_ok, sched_err = ngx.timer.at(delay, tick)
    if not sched_ok then
      ngx.log(ngx.ERR, "self_identity: failed to reschedule: ", sched_err)
    end
    delay = math.min(delay * 2, self.max_interval)
  end
  local ok, err = ngx.timer.at(0, tick)
  if not ok then
    ngx.log(ngx.ERR, "self_identity: failed to start: ", err)
  end
end

return _M
