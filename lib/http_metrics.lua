-- http_metrics.lua
-- Thin orchestration layer: wires this fork's pure lib/ modules --
-- route_sanitizer, host_classifier, client_subnet, gauge_expiry,
-- source_attribution, app_toggle -- into the upstream `prometheus`
-- library's counter/gauge/histogram API, driven entirely by
-- lib/metrics_config.lua. This file has no environment-specific values in
-- it; edit metrics_config.lua instead.
--
-- Wired up from default.conf as:
--   init_worker_by_lua_block { require("http_metrics").init() }
--   access_by_lua_block      { require("http_metrics").classify_source() }
--   log_by_lua_block         { require("http_metrics").record() }
--   content_by_lua_block     { require("http_metrics").collect() }   -- in location = /metrics

local route_sanitizer    = require("route_sanitizer")
local host_classifier    = require("host_classifier")
local client_subnet      = require("client_subnet")
local gauge_expiry       = require("gauge_expiry")
local source_attribution = require("source_attribution")
local app_toggle         = require("app_toggle")

local config = require("metrics_config")
local cfg    = config.http
local apps   = config.apps

local _M = {}

-- populated in init()
local prometheus
local metric_requests, metric_latency, metric_latency_histogram
local metric_request_size, metric_request_size_histogram
local metric_response_size, metric_response_size_histogram
local metric_connections
local metric_connection_requests, metric_connection_requests_histogram
local metric_connection_time, metric_connection_time_histogram
local expiry
local resolver

local function build_label_schema()
    local l = {}
    if cfg.label_method            then table.insert(l, "method")           end
    if cfg.label_route             then table.insert(l, "route")            end
    if cfg.label_status            then table.insert(l, "status")           end
    if cfg.label_client_subnet     then table.insert(l, "client_subnet")    end
    if cfg.label_host              then table.insert(l, "host")             end
    if cfg.label_app               then table.insert(l, "app")              end
    if cfg.label_namespace         then table.insert(l, "namespace")        end
    if cfg.label_mode              then table.insert(l, "mode")             end
    if cfg.label_source_service    then table.insert(l, "source_service")   end
    if cfg.label_source_namespace  then table.insert(l, "source_namespace") end
    return l
end

local function build_labels(method, route, status, subnet, host, mode, source_service, source_namespace)
    local l = {}
    if cfg.label_method            then table.insert(l, method)           end
    if cfg.label_route             then table.insert(l, route)            end
    if cfg.label_status            then table.insert(l, status)           end
    if cfg.label_client_subnet     then table.insert(l, subnet)           end
    if cfg.label_host              then table.insert(l, host)             end
    if cfg.label_mode              then table.insert(l, mode)             end
    if cfg.label_source_service    then table.insert(l, source_service)   end
    if cfg.label_source_namespace  then table.insert(l, source_namespace) end
    if cfg.label_app               then table.insert(l, cfg.app)          end
    if cfg.label_namespace         then table.insert(l, cfg.namespace)    end
    return l
end

-- ============================================================
-- init_worker_by_lua_block
-- ============================================================
function _M.init()
    local label_schema = build_label_schema()
    local conn_label_schema = {"app", "namespace"}

    prometheus = require("prometheus").init("prometheus_metrics")

    if cfg.metric_requests then
        metric_requests = prometheus:counter(
            "nginx_http_requests_total", "Number of HTTP requests", label_schema)
    end
    if cfg.metric_latency then
        metric_latency = prometheus:gauge(
            "nginx_http_request_duration_seconds", "Duration of last HTTP request in seconds", label_schema)
    end
    if cfg.metric_latency_hist then
        metric_latency_histogram = prometheus:histogram(
            "nginx_http_request_duration_seconds_histogram", "HTTP request duration histogram in seconds",
            label_schema, cfg.histogram_buckets)
    end
    if cfg.metric_request_size then
        metric_request_size = prometheus:gauge(
            "nginx_http_request_size_bytes", "Size of last HTTP request in bytes", label_schema)
    end
    if cfg.metric_request_size_histogram then
        metric_request_size_histogram = prometheus:histogram(
            "nginx_http_request_size_bytes_histogram", "HTTP request size histogram in bytes",
            label_schema, cfg.histogram_buckets_req_size)
    end
    if cfg.metric_response_size then
        metric_response_size = prometheus:gauge(
            "nginx_http_response_size_bytes", "Size of last HTTP response in bytes", label_schema)
    end
    if cfg.metric_response_size_histogram then
        metric_response_size_histogram = prometheus:histogram(
            "nginx_http_response_size_bytes_histogram", "HTTP response size histogram in bytes",
            label_schema, cfg.histogram_buckets_res_size)
    end
    if cfg.metric_connections then
        metric_connections = prometheus:gauge(
            "nginx_http_connections", "Number of HTTP connections by state", {"state", "app", "namespace"})
    end
    if cfg.metric_connection_requests then
        metric_connection_requests = prometheus:gauge(
            "nginx_connection_requests", "Number of requests made on the current connection", conn_label_schema)
    end
    if cfg.metric_connection_requests_histogram then
        metric_connection_requests_histogram = prometheus:histogram(
            "nginx_connection_requests_histogram", "Distribution of requests per connection",
            conn_label_schema, cfg.histogram_buckets_conn_requests)
    end
    if cfg.metric_connection_time then
        metric_connection_time = prometheus:gauge(
            "nginx_connection_time_seconds", "Time the current connection has been open in seconds", conn_label_schema)
    end
    if cfg.metric_connection_time_histogram then
        metric_connection_time_histogram = prometheus:histogram(
            "nginx_connection_time_seconds_histogram", "Distribution of connection lifetimes in seconds",
            conn_label_schema, cfg.histogram_buckets_conn_time)
    end

    -- ============================================================
    -- Gauge expiry -- one tracker shared by both the "req" and "conn"
    -- scopes; see lib/gauge_expiry.lua
    -- ============================================================
    if cfg.metric_latency or cfg.metric_request_size or cfg.metric_response_size
       or cfg.metric_connection_requests or cfg.metric_connection_time then
        expiry = gauge_expiry.new{
            dict       = ngx.shared.custom_metrics,
            window     = cfg.expiry_window,
            scan_limit = cfg.expiry_scan_limit,
        }
        expiry:start(5, function(scope, labels)
            if scope == "req" then
                if metric_latency       then metric_latency:set(0, labels)       end
                if metric_request_size  then metric_request_size:set(0, labels)  end
                if metric_response_size then metric_response_size:set(0, labels) end
            elseif scope == "conn" then
                if metric_connection_requests then metric_connection_requests:set(0, labels) end
                if metric_connection_time     then metric_connection_time:set(0, labels)     end
            end
        end)
    end

    -- ============================================================
    -- Caller-identification resolver -- see lib/source_attribution.lua
    -- ============================================================
    resolver = source_attribution.new_resolver{
        dict               = ngx.shared.ptr_cache,
        cache_ttl          = cfg.ptr_cache_ttl,
        dns                = { nameservers = {{ cfg.ptr_dns_server, 53 }}, timeout_ms = cfg.ptr_dns_timeout },
        dynamic_prefix     = cfg.dynamic_prefix,
        static_ranges      = cfg.static_ranges,
        default_label      = cfg.default_label,
        default_namespace  = cfg.default_namespace,
        default_service    = cfg.probe_default_service,
    }
end

-- ============================================================
-- access_by_lua_block -- classify request source (static / PTR / mesh)
-- ============================================================
function _M.classify_source()
    if ngx.var.request_mode == "1" then
        -- outbound (forward-proxy) leg: the caller is this pod itself
        ngx.ctx.source_service   = cfg.app
        ngx.ctx.source_namespace = cfg.namespace
        return
    end

    local service, namespace = resolver:resolve(ngx.var.remote_addr)

    -- mesh override: only trusts XFCC once the direct peer has already been
    -- independently confirmed (via the PTR-based resolve() above) to be the
    -- waypoint itself -- see lib/source_attribution.lua's docstring on why
    -- this ordering matters.
    service, namespace = source_attribution.apply_waypoint_override(
        service, namespace, ngx.var.http_x_forwarded_client_cert, cfg.waypoint_service_name)

    ngx.ctx.source_service   = service
    ngx.ctx.source_namespace = namespace
end

-- ============================================================
-- log_by_lua_block -- record request/response/connection metrics
-- ============================================================
function _M.record()
    -- forward-proxy master switch: skip recording entirely for outbound
    -- (mode=1) traffic when disabled in metrics_config.apps.forward_proxy -- the proxy
    -- itself keeps running either way, see lib/app_toggle.lua.
    if (ngx.var.request_mode or "0") == "1" and not app_toggle.enabled(apps, "forward_proxy") then
        return
    end

    local method   = ngx.var.request_method or "UNKNOWN"
    local status   = ngx.var.status or "000"
    local req_time = tonumber(ngx.var.request_time) or 0
    local req_size = tonumber(ngx.var.request_length) or 0
    local res_size = tonumber(ngx.var.body_bytes_sent) or 0
    local subnet   = cfg.label_client_subnet and client_subnet.mask(ngx.var.http_x_forwarded_for or ngx.var.remote_addr) or nil
    local host     = cfg.label_host and host_classifier.classify(ngx.var.host, cfg.cluster_ip_prefix) or nil
    local mode     = cfg.label_mode and (ngx.var.request_mode or "0") or nil
    local route    = route_sanitizer.sanitize(ngx.var.request_uri, cfg.sanitize)

    local labels = build_labels(method, route, status, subnet, host, mode, ngx.ctx.source_service, ngx.ctx.source_namespace)

    if metric_requests           then metric_requests:inc(1, labels)             end
    if metric_latency            then metric_latency:set(req_time, labels)       end
    if metric_latency_histogram  then metric_latency_histogram:observe(req_time, labels) end
    if metric_request_size       then metric_request_size:set(req_size, labels)  end
    if metric_request_size_histogram  then metric_request_size_histogram:observe(req_size, labels)  end
    if metric_response_size      then metric_response_size:set(res_size, labels) end
    if metric_response_size_histogram then metric_response_size_histogram:observe(res_size, labels) end

    if expiry and (metric_latency or metric_request_size or metric_response_size) then
        expiry:touch("req", labels)
    end

    -- ── connection-level metrics (no route/method/status; a connection can carry multiple requests) ──
    local conn_reqs   = tonumber(ngx.var.connection_requests) or 1
    local conn_time   = tonumber(ngx.var.connection_time) or 0
    local conn_labels = {cfg.app, cfg.namespace}

    if metric_connection_requests           then metric_connection_requests:set(conn_reqs, conn_labels) end
    if metric_connection_requests_histogram then metric_connection_requests_histogram:observe(conn_reqs, conn_labels) end
    if metric_connection_time               then metric_connection_time:set(conn_time, conn_labels) end
    if metric_connection_time_histogram     then metric_connection_time_histogram:observe(conn_time, conn_labels) end

    if expiry and (metric_connection_requests or metric_connection_time) then
        expiry:touch("conn", conn_labels)
    end

    if metric_connections then
        metric_connections:set(ngx.var.connections_active  or 0, {"active",  cfg.app, cfg.namespace})
        metric_connections:set(ngx.var.connections_reading or 0, {"reading", cfg.app, cfg.namespace})
        metric_connections:set(ngx.var.connections_writing or 0, {"writing", cfg.app, cfg.namespace})
        metric_connections:set(ngx.var.connections_waiting or 0, {"waiting", cfg.app, cfg.namespace})
    end
end

-- exposed for the /metrics location on :80
function _M.collect()
    if metric_connections then
        metric_connections:set(ngx.var.connections_reading, {"reading", cfg.app, cfg.namespace})
        metric_connections:set(ngx.var.connections_waiting, {"waiting", cfg.app, cfg.namespace})
        metric_connections:set(ngx.var.connections_writing, {"writing", cfg.app, cfg.namespace})
    end
    prometheus:collect()
end

return _M
