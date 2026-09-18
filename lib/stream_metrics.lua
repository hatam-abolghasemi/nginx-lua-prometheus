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
--   log_by_lua_block         { require("stream_metrics").record() }   -- inside each destination's server{}
--   content_by_lua_block     { ngx.print(require("stream_metrics").metric_data()) }

local gauge_expiry = require("gauge_expiry")
local app_toggle    = require("app_toggle")

local config = require("metrics_config")
local cfg    = config.stream
local apps   = config.apps.stream

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

local function build_label_schema()
    local l = {}
    if cfg.label_destination   then table.insert(l, "destination")    end
    if cfg.label_upstream_addr then table.insert(l, "upstream_addr")  end
    if cfg.label_status        then table.insert(l, "status")         end
    return l
end

function _M.init()
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
            "Active/reading/writing/waiting stream connections", {"state"})
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

function _M.record()
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

    if metric_stream_connections_active then
        metric_stream_connections_active:set(ngx.var.connections_active  or 0, {"active"})
        metric_stream_connections_active:set(ngx.var.connections_reading or 0, {"reading"})
        metric_stream_connections_active:set(ngx.var.connections_writing or 0, {"writing"})
        metric_stream_connections_active:set(ngx.var.connections_waiting or 0, {"waiting"})
    end
end

-- exposed for the :9254 exposition server -- this exporter's own registry
-- only; the HTTP registry is scraped separately on :80/metrics.
function _M.metric_data()
    return table.concat(prometheus_stream:metric_data())
end

return _M
