-- metrics_config.lua
-- All environment-specific values for this fork's HTTP and stream metrics
-- (app/namespace names, which metrics and labels are enabled, histogram
-- buckets, source-attribution ranges, per-app toggles) in one place.
--
-- This is the one file under lib/ meant to be edited per deployment --
-- every other lib/*.lua module is generic code with no environment-specific
-- values in it. Being plain data (a table, no logic), it's also a natural
-- fit for shipping via its own ConfigMap if you want config changes to not
-- require rebuilding the nginx image -- see examples/openresty-sidecar/k8s/.
--
-- Consumed by lib/http_metrics.lua (the `http` and `apps` tables) and
-- lib/stream_metrics.lua (the `stream` and `apps.stream` tables).
--
-- Replace every example value below (app/namespace names, IP ranges,
-- resolver IP, static_ranges zone map) with your own before deploying.

return {
    -- per-app / per-destination metrics master switches (lib/app_toggle.lua)
    -- -- an app/destination with no entry here defaults to enabled. The
    -- proxy/traffic itself keeps running regardless of this switch; it only
    -- stops metrics being recorded for that leg.
    apps = {
        forward_proxy = { metrics_enabled = true },  -- checked by http_metrics.lua
        stream = {                                    -- checked by stream_metrics.lua, keyed by destination_name
            redis = { metrics_enabled = true },
        },
    },

    http = {
        -- This pod's own identity. With discover_identity on, the service and
        -- namespace are discovered at runtime via reverse DNS (lib/self_identity.lua,
        -- the same mechanism that identifies callers), so ONE shared config can serve
        -- several Deployments. app / namespace below are then only the fallback used
        -- until discovery succeeds (or forever if it can't: no PTR records, hostNetwork).
        -- With discover_identity = false they're used as-is, so give each Deployment its own.
        discover_identity                    = true,
        app                                  = "example-app",
        namespace                            = "example-namespace",
        expiry_window                        = 10,
        expiry_scan_limit                    = 10000,  -- bounds get_keys(); unbounded scans block all workers under high cardinality
        cluster_ip_prefix                    = "10.233.",  -- must end in "."; verify per-cluster

        metric_requests                      = true,
        metric_latency                       = true,
        metric_latency_hist                  = true,
        metric_request_size                  = true,
        metric_request_size_histogram        = false,
        metric_response_size                 = true,
        metric_response_size_histogram       = false,
        metric_connections                   = true,
        metric_connection_requests           = true,
        metric_connection_requests_histogram = false,
        metric_connection_time               = true,
        metric_connection_time_histogram     = false,

        histogram_buckets                    = {0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1, 2.5, 5, 10},
        histogram_buckets_req_size           = {64, 256, 1024, 4096, 16384, 65536, 262144, 1048576},
        histogram_buckets_res_size           = {64, 256, 1024, 4096, 16384, 65536, 262144, 1048576},
        histogram_buckets_conn_requests      = {1, 2, 5, 10, 25, 50, 100, 250},
        histogram_buckets_conn_time          = {0.1, 0.5, 1, 5, 15, 30, 60, 300},

        label_method           = true,
        label_route            = true,
        label_status           = true,
        label_app              = false,
        label_namespace        = false,
        label_client_subnet    = false,  -- remote_addr as x.x.x.0/24; source_service/namespace below is usually the more useful label
        label_host             = true,
        label_mode             = true,   -- 0 = reverse-proxy/incoming, 1 = forward-proxy/outgoing
        label_source_service   = true,
        label_source_namespace = true,

        -- passed straight through to route_sanitizer.sanitize()
        sanitize = {
            pure_numeric      = true,
            uuid              = true,
            hex               = true,
            slug_suffix_digit = true,
            long_with_digit   = true,
            file_extension    = true,
            min_len           = 4,
            max_segment_len   = 64,
        },

        -- passed straight through to source_attribution.new_resolver()
        dynamic_prefix   = {10, 233},   -- pod CIDR: too dynamic for a static table, deferred to PTR
        static_ranges = {
            { prefix = {192, 168}, label = "internal",
              zone_map = { [104] = "zone_a", [108] = "zone_a", [116] = "zone_a",
                           [140] = "zone_b", [141] = "zone_b", [142] = "zone_b",
                           [200] = "zone_c", [201] = "zone_c",
                           [212] = "zone_d", [213] = "zone_d" } },
        },
        default_label     = "public",
        default_namespace = "unknown",

        ptr_dns_server           = "10.233.0.3",  -- your CoreDNS ClusterIP; fetch per-cluster, do not hardcode in production
        ptr_dns_timeout          = 200,   -- ms; kept tight, falls back to defaults on timeout
        ptr_cache_ttl            = 15,    -- seconds, matches CoreDNS record TTL
        probe_default_service    = "health-probe",  -- fallback for unresolved dynamic-range addresses (often kubelet probes)
        probe_default_namespace  = "default",
        waypoint_service_name    = "waypoint",  -- must match the Service name your mesh's waypoint Gateway creates
    },

    stream = {
        expiry_window     = 10,
        expiry_scan_limit = 10000,

        metric_connections_total           = true,
        metric_bytes_sent                  = true,
        metric_bytes_received              = true,
        metric_session_duration            = true,   -- histogram
        metric_session_duration_gauge      = true,    -- gauge, last value (companion to the histogram)
        metric_upstream_connect_time_gauge = true,    -- gauge, last value
        metric_upstream_connect_time_hist  = true,    -- histogram
        metric_connections_active          = true,
        metric_upstream_bytes_sent         = true,
        metric_upstream_bytes_received     = true,
        metric_upstream_first_byte_time    = true,

        label_destination    = true,
        label_upstream_addr  = true,
        label_status         = true,

        histogram_buckets_session_duration = {0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 15, 30, 60},
        histogram_buckets_connect_time     = {0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1},
    },
}