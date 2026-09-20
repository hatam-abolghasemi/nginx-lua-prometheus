-- stream_metrics.lua
-- Thin orchestration layer, the stream-module counterpart to
-- http_metrics.lua: wires lib/gauge_expiry.lua and lib/app_toggle.lua into
-- the upstream `prometheus` library's counter/gauge/histogram API for
-- proxied TCP/UDP destinations, driven entirely by lib/metrics_config.lua.
-- This file has no environment-specific values in it; edit
-- metrics_config.lua instead.
--
-- Wired up from stream.conf as:
--   init_worker_by_lua_block { require("stream_metrics").init() }
--   preread_by_lua_block     { require("stream_metrics").connection_open() }  -- inside each destination's server{}
--   log_by_lua_block         { require("stream_metrics").record() }   -- inside each destination's server{}
--   content_by_lua_block     { ngx.print(require("stream_metrics").metric_data()) }
--
-- Source labels (source_service / source_namespace, off unless enabled in
-- metrics_config.stream): who opened the connection. Same meaning as on the
-- HTTP metrics. For a loopback listener (the usual sidecar setup: the app
-- container connects to 127.0.0.1:<port>) the client is this pod itself, so
-- the label is the pod's own discovered identity (lib/self_identity.lua);
-- for any other client it's resolved like an HTTP caller (static ranges, then
-- PTR). Needs `lua_shared_dict stream_ptr_cache` in stream.conf; without it
-- the source labels are switched off and an error is logged.

local gauge_expiry       = require("gauge_expiry")
local app_toggle         = require("app_toggle")
local self_identity      = require("self_identity")
local source_attribution = require("source_attribution")

local config   = require("metrics_config")
local cfg      = config.stream
local http_cfg = config.http     -- own identity + caller-attribution settings are shared with HTTP
local apps     = config.apps.stream

local _M = {}

local prometheus_stream
local metric_stream_connections
local metric_stream_bytes_sent
local metric_stream_bytes_received
local metric_stream_session_duration_hist
local metric_stream_session_duration_gauge
local metric_stream_upstream_connect_time_gauge
local metric_stream_upstream_connect_time_hist
local metric_stream_connections_active
local metric_stream_upstream_bytes_sent
local metric_stream_upstream_bytes_received
local metric_stream_upstream_first_byte_time
local expiry
local resolver
local ident            -- this pod's own service/namespace (lib/self_identity.lua)
local source_on = false  -- decided in init(): source labels wanted AND stream_ptr_cache exists

-- This pod's own service/namespace: discovered when http.discover_identity is
-- on (http.app / http.namespace are then only the fallback), else as configured.
local function own()
    if ident then return ident:get() end
    return http_cfg.app, http_cfg.namespace
end

-- Loopback / unix-socket clients are this pod's own containers.
local function is_local(addr)
    return addr == nil or addr == "" or addr == "::1"
        or addr:match("^127%.") ~= nil or addr:sub(1, 5) == "unix:"
end

-- Runs in preread (cosockets allowed). Must never raise: an error in
-- preread_by_lua would drop the client's connection.
local function classify_source()
    local addr = ngx.var.remote_addr
    if is_local(addr) then return own() end
    local ok, svc, ns = pcall(resolver.resolve, resolver, addr)
    if ok and svc then return svc, ns or resolver.default_namespace end
    return resolver.default_service, resolver.default_namespace
end

-- Source for the current session, safe in the log phase (no cosockets): what
-- preread stored, else a cheap local answer so the label count always matches.
local function source_values()
    local svc, ns = ngx.ctx.stream_source_service, ngx.ctx.stream_source_namespace
    if svc then return svc, ns end
    if is_local(ngx.var.remote_addr) then return own() end
    return resolver.default_service, resolver.default_namespace
end

local function build_label_schema()
    local l = {}
    if cfg.label_destination   then table.insert(l, "destination")    end
    if cfg.label_upstream_addr then table.insert(l, "upstream_addr")  end
    if cfg.label_status        then table.insert(l, "status")         end
    if source_on and cfg.label_source_service   then table.insert(l, "source_service")   end
    if source_on and cfg.label_source_namespace then table.insert(l, "source_namespace") end
    return l
end

function _M.init()
    -- source attribution must be settled before the label schema is built
    if cfg.label_source_service or cfg.label_source_namespace then
        local dict = ngx.shared.stream_ptr_cache
        if not dict then
            ngx.log(ngx.ERR, "stream_metrics: source labels are enabled but `lua_shared_dict ",
                    "stream_ptr_cache` is not declared in stream.conf -- source labels disabled")
        else
            source_on = true
            resolver = source_attribution.new_resolver{
                dict              = dict,
                cache_ttl         = http_cfg.ptr_cache_ttl,
                dns               = { nameservers = {{ http_cfg.ptr_dns_server, 53 }}, timeout_ms = http_cfg.ptr_dns_timeout },
                dynamic_prefix    = http_cfg.dynamic_prefix,
                static_ranges     = http_cfg.static_ranges,
                default_label     = http_cfg.default_label,
                default_namespace = http_cfg.default_namespace,
                default_service   = http_cfg.probe_default_service,
            }
            if http_cfg.discover_identity then
                ident = self_identity.new{
                    resolver           = resolver,
                    fallback_service   = http_cfg.app,
                    fallback_namespace = http_cfg.namespace,
                }
                ident:start()
            end
        end
    end

    local label_schema = build_label_schema()

    prometheus_stream = require("prometheus").init("stream_metrics")

    if cfg.metric_connections_total then
        metric_stream_connections = prometheus_stream:counter(
            "nginx_stream_connections_total", "Total TCP/UDP connections proxied", label_schema)
    end
    if cfg.metric_bytes_sent then
        metric_stream_bytes_sent = prometheus_stream:counter(
            "nginx_stream_bytes_sent_total", "Bytes sent to client", label_schema)
    end
    if cfg.metric_bytes_received then
        metric_stream_bytes_received = prometheus_stream:counter(
            "nginx_stream_bytes_received_total", "Bytes received from client", label_schema)
    end
    if cfg.metric_session_duration then
        metric_stream_session_duration_hist = prometheus_stream:histogram(
            "nginx_stream_session_duration_seconds_histogram", "Duration of proxied TCP/UDP session",
            label_schema, cfg.histogram_buckets_session_duration)
    end
    if cfg.metric_session_duration_gauge then
        metric_stream_session_duration_gauge = prometheus_stream:gauge(
            "nginx_stream_session_duration_seconds",
            "Duration of the most recently completed session (last value)", label_schema)
    end
    if cfg.metric_upstream_connect_time_gauge then
        metric_stream_upstream_connect_time_gauge = prometheus_stream:gauge(
            "nginx_stream_upstream_connect_time_seconds",
            "Time to establish the last upstream connection", label_schema)
    end
    if cfg.metric_upstream_connect_time_hist then
        metric_stream_upstream_connect_time_hist = prometheus_stream:histogram(
            "nginx_stream_upstream_connect_time_seconds_histogram",
            "Upstream connect time histogram", label_schema, cfg.histogram_buckets_connect_time)
    end
    if cfg.metric_connections_active then
        metric_stream_connections_active = prometheus_stream:gauge(
            "nginx_stream_connections_active",
            "Currently open proxied stream connections", {"state"})
    end
    if cfg.metric_upstream_bytes_sent then
        metric_stream_upstream_bytes_sent = prometheus_stream:counter(
            "nginx_stream_upstream_bytes_sent_total",
            "Bytes sent to the upstream (destination)", label_schema)
    end
    if cfg.metric_upstream_bytes_received then
        metric_stream_upstream_bytes_received = prometheus_stream:counter(
            "nginx_stream_upstream_bytes_received_total",
            "Bytes received from the upstream (destination)", label_schema)
    end
    if cfg.metric_upstream_first_byte_time then
        metric_stream_upstream_first_byte_time = prometheus_stream:histogram(
            "nginx_stream_upstream_first_byte_time_seconds",
            "Time to first byte from upstream", label_schema, cfg.histogram_buckets_connect_time)
    end

    -- ============================================================
    -- Gauge expiry -- reuses lib/gauge_expiry.lua exactly as
    -- http_metrics.lua does, just against the stream-only shared dicts.
    -- ============================================================
    if cfg.metric_upstream_connect_time_gauge or cfg.metric_session_duration_gauge then
        expiry = gauge_expiry.new{
            dict       = ngx.shared.stream_custom_metrics,
            window     = cfg.expiry_window,
            scan_limit = cfg.expiry_scan_limit,
        }
        expiry:start(5, function(_, labels)
            if metric_stream_upstream_connect_time_gauge then
                metric_stream_upstream_connect_time_gauge:set(0, labels)
            end
            if metric_stream_session_duration_gauge then
                metric_stream_session_duration_gauge:set(0, labels)
            end
        end)
    end
end

-- Call from preread_by_lua_block in every destination server{}.
--
-- nginx's stream module has no stub_status: $connections_active/reading/
-- writing/waiting are HTTP-only variables and are nil here, so the gauge is
-- maintained by hand -- +1 when a session starts (here), -1 when it ends
-- (record(), from log_by_lua_block, which always runs at session close).
-- Only the "active" state is meaningful for stream; reading/writing/waiting
-- have no stream equivalent and are not exported.
function _M.connection_open()
    if not app_toggle.enabled(apps, ngx.var.destination_name) then return end

    if source_on then
        ngx.ctx.stream_source_service, ngx.ctx.stream_source_namespace = classify_source()
    end

    if metric_stream_connections_active then
        -- remember that this session was counted, so record() only
        -- decrements sessions that were actually incremented (a server{}
        -- missing its preread hook, or a toggled-off destination, can't
        -- drive it negative).
        ngx.ctx.stream_active_counted = true
        metric_stream_connections_active:inc(1, {"active"})
    end
end

function _M.record()
    if ngx.ctx.stream_active_counted then
        ngx.ctx.stream_active_counted = nil
        metric_stream_connections_active:inc(-1, {"active"})
    end

    -- per-destination master switch: an entry with no metrics_enabled (or
    -- no entry at all) in metrics_config.apps.stream defaults to enabled -- see
    -- lib/app_toggle.lua.
    local destination = ngx.var.destination_name
    if not app_toggle.enabled(apps, destination) then
        return
    end

    local labels = {}
    if cfg.label_destination   then table.insert(labels, destination) end
    if cfg.label_upstream_addr then table.insert(labels, ngx.var.upstream_addr or "none") end
    if cfg.label_status        then table.insert(labels, ngx.var.status or "unknown") end
    if source_on then
        local src_svc, src_ns = source_values()
        if cfg.label_source_service   then table.insert(labels, src_svc or "unknown") end
        if cfg.label_source_namespace then table.insert(labels, src_ns  or "unknown") end
    end

    if metric_stream_connections    then metric_stream_connections:inc(1, labels) end
    if metric_stream_bytes_sent     then metric_stream_bytes_sent:inc(tonumber(ngx.var.bytes_sent) or 0, labels) end
    if metric_stream_bytes_received then metric_stream_bytes_received:inc(tonumber(ngx.var.bytes_received) or 0, labels) end

    local session_time = tonumber(ngx.var.session_time) or 0
    if metric_stream_session_duration_hist  then metric_stream_session_duration_hist:observe(session_time, labels) end
    if metric_stream_session_duration_gauge then metric_stream_session_duration_gauge:set(session_time, labels) end

    if metric_stream_upstream_bytes_sent then
        metric_stream_upstream_bytes_sent:inc(tonumber(ngx.var.upstream_bytes_sent) or 0, labels)
    end
    if metric_stream_upstream_bytes_received then
        metric_stream_upstream_bytes_received:inc(tonumber(ngx.var.upstream_bytes_received) or 0, labels)
    end

    local first_byte_time = tonumber(ngx.var.upstream_first_byte_time)
    if first_byte_time and metric_stream_upstream_first_byte_time then
        metric_stream_upstream_first_byte_time:observe(first_byte_time, labels)
    end

    local connect_time = tonumber(ngx.var.upstream_connect_time)
    if connect_time then
        if metric_stream_upstream_connect_time_gauge then metric_stream_upstream_connect_time_gauge:set(connect_time, labels) end
        if metric_stream_upstream_connect_time_hist  then metric_stream_upstream_connect_time_hist:observe(connect_time, labels) end
    end

    if expiry and (metric_stream_upstream_connect_time_gauge or metric_stream_session_duration_gauge) then
        expiry:touch("stream_time", labels)
    end
end

-- exposed for the :9254 exposition server -- this exporter's own registry
-- only; the HTTP registry is scraped separately on :80/metrics.
function _M.metric_data()
    return table.concat(prometheus_stream:metric_data())
end

return _M
