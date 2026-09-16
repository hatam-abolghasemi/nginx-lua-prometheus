# Fork notes

This repository is a fork of
[knyar/nginx-lua-prometheus](https://github.com/knyar/nginx-lua-prometheus),
a Prometheus metrics library for Nginx written in Lua, MIT licensed.
Credit for the library — `prometheus.lua`, `prometheus_keys.lua`,
`prometheus_resty_counter.lua`, and the counter/gauge/histogram API — belongs
to the upstream project and its contributors. **None of those files are
modified here.** This fork adds a reference deployment on top of the
library's public API; it does not change the library itself, so upstream
releases can still be pulled in cleanly.

The addition is split across two places:

- **[`lib/`](lib/)** — five requirable Lua modules, one per concern
  (`route_sanitizer.lua`, `host_classifier.lua`, `client_subnet.lua`,
  `gauge_expiry.lua`, `source_attribution.lua`), following the same
  `require()`-a-module pattern as the upstream library itself. Pure logic
  (string parsing, key encoding, classification rules) is separated from
  the nginx-specific orchestration (shared dicts, timers, DNS resolution)
  wherever the two were tangled together, specifically so the pure parts
  can be unit-tested without a running nginx worker.
- **[`examples/openresty-sidecar/default.conf`](examples/openresty-sidecar/default.conf)**
  — a complete OpenResty configuration that `require()`s those modules to
  build request metrics, caller identification, and an egress forward proxy
  into one sidecar process. Example values (service names, namespaces, IP
  ranges) are placeholders — substitute your own before deploying.

### Running the tests

Each `lib/` module has a matching `tests/*_test.lua` file using `luaunit`,
the same testing library the upstream project uses for `prometheus_test.lua`.
From the repo root:

```
luarocks install luaunit   # if not already installed
for f in tests/*_test.lua; do lua5.1 "$f" || exit 1; done
```

All modules are pure Lua with injectable dependencies (fake shared dicts,
a fake DNS resolver) where they'd otherwise need a real nginx worker —
see `tests/source_attribution_test.lua` for the pattern used to test DNS/cache
orchestration without live DNS traffic.

Each section below covers one addition: what it is, why it exists, how it
works, what it requires to function correctly, how to verify it's working,
what it assumes about your environment, and what to watch for as things
change.

| Section | Module | Depends on nginx runtime? |
|---|---|---|
| 1. Route sanitization | `lib/route_sanitizer.lua` | No — pure Lua |
| 2. Client subnet masking | `lib/client_subnet.lua` | No — pure Lua |
| 3. Host classification | `lib/host_classifier.lua` | No — pure Lua |
| 4. `source_service`/`source_namespace` | `lib/source_attribution.lua` | Only the stateful `Resolver`; the parsing functions (`classify_static`, `parse_ptr`, `parse_xfcc`) are pure |
| 5. Waypoint / XFCC override | `lib/source_attribution.lua` (`apply_waypoint_override`) | No — pure Lua |
| 6. Gauge expiry | `lib/gauge_expiry.lua` | Only `:start()`; `:touch()`/`:sweep()`/key encoding are pure |
| 7. Connection-level metrics | (usage pattern in the example config, built on `gauge_expiry`) | Yes — reads live nginx connection variables |
| 8. Forward proxy | (nginx config + patched OpenResty build) | Yes — this is infrastructure, not a Lua module |

---

## 1. Route sanitization

**What it is.** Before a request's URI becomes the `route` label, path
segments matching common identifier shapes are collapsed into a `$param`
placeholder: pure numbers, UUIDs, hex tokens, slugs with a trailing number,
long alphanumeric segments, and file extensions.

**Why.** Prometheus label values are meant to be low-cardinality. A raw path
like `/orders/8231` and `/orders/8232` would otherwise create a separate,
permanent time series per order ID — cardinality that never stops growing and
that Prometheus's storage engine handles poorly at scale.

**How it works.** `route_sanitizer.is_param_segment()` runs each `/`-delimited path segment
through six independent checks (`sanitize_pure_numeric`, `sanitize_uuid`,
`sanitize_hex`, `sanitize_slug_suffix_digit`, `sanitize_long_with_digit`,
`sanitize_file_extension`), each toggleable in `cfg`. A segment matching any
enabled check becomes `$param`; consecutive `$param` segments collapse into
one. `/orders/8231/items/9f8a3c2e-...` becomes `/orders/$param/items/$param`.

**Requirements.** None beyond the config itself — this is pure Lua string
matching with no external dependency.

**How to verify.** Query `/metrics` and confirm the `route` label values are
bounded shapes, not raw paths — e.g. grep for a known dynamic ID from a
recent request and confirm it does *not* appear verbatim in any `route=`
label. Watch cardinality over time with
`count(count by (route) (nginx_http_requests_total))`; it should plateau as
traffic patterns stabilize, not grow linearly with request volume.

**Assumptions.** Identifier shapes match the six patterns above. An
identifier scheme that doesn't fit any of them (e.g. short alphabetic codes)
will pass through unsanitized and needs its own rule added.

**Keeping it updated.** If a new path convention is introduced (a new ID
format, a new file type in URLs), add a check to `route_sanitizer.is_param_segment()` rather
than disabling sanitization — the goal is precision, not turning it off.

---

## 2. Client subnet masking

**What it is.** `remote_addr` (or `X-Forwarded-For`) is truncated to a `/24`
for RFC1918 ranges and a `/16` for public IPs before use as a label.

**Why.** Same cardinality concern as routes — one label value per client IP
is unbounded, especially in a Kubernetes pod network where IPs churn
constantly.

**How it works.** `client_subnet.mask()` parses the first IP in the header,
zeroes the last octet (private ranges) or last two octets (public ranges),
and returns the result as a string.

**Requirements.** None. Disabled by default (`label_client_subnet = false`)
since `source_service`/`source_namespace` (section 4) is normally the more
useful caller-identification label; enable this only if you need raw subnet
visibility independent of PTR resolution.

**How to verify.** Confirm `client_subnet` label values end in `.0` (private)
or `.0.0` (public), never a specific host address.

**Assumptions.** IPv4 only — the function returns `"unknown"` for anything
that doesn't match the IPv4 pattern, including IPv6 literals.

**Keeping it updated.** No maintenance needed unless your addressing scheme
changes (e.g. adopting IPv6, in which case this function needs an IPv6 branch).

---

## 3. Host classification

**What it is.** The `Host` header is classified into `"localhost"`, an
internal-cluster marker (`"kubernetes"`), a generic `"$ip"` bucket, or passed
through unchanged if it's a real domain name.

**Why.** Without this, any request bearing a raw pod or service IP in its
`Host` header creates a new label value per IP — again, unbounded
cardinality, and unlike routes or client IPs, the `Host` header is fully
attacker- or client-controlled.

**How it works.** `host_classifier.classify()` checks the header against a loopback
literal, an IPv4 pattern (checked against `cfg.cluster_ip_prefix` to decide
`"kubernetes"` vs `"$ip"`), and a loose IPv6 literal check.

**Requirements.** `cfg.cluster_ip_prefix` must match your cluster's actual
pod/service CIDR prefix, or internal IPs will be classified as generic
`"$ip"` instead of `"kubernetes"` — functionally fine, just less informative.

**How to verify.** Send a request with `Host: <a-pod-ip>` and confirm it
reports as `"kubernetes"` in `/metrics`, not the raw IP.

**Assumptions.** One contiguous CIDR prefix describes "internal" traffic.
Multi-CIDR clusters (e.g. separate pod and service ranges that don't share a
prefix) need `cluster_ip_prefix` generalized to a list-and-match instead of a
single string prefix.

**Keeping it updated.** Re-verify `cluster_ip_prefix` after any cluster CIDR
change (cluster migration, CNI reconfiguration, IP range expansion).

---

## 4. `source_service` / `source_namespace` labels

**What it is.** Every inbound request is labeled with the identity of its
caller — which service and namespace made the call — not just the request's
own method, route, and status.

**Why.** Route and status labels describe *what* happened; they say nothing
about *who* called. Without caller identity, diagnosing "which service is
hammering this endpoint" or "who's still calling this deprecated route"
requires cross-referencing access logs by hand. This makes it a first-class,
queryable Prometheus label.

**How it works**, in resolution order:

1. **Static classification** (`source_attribution.classify_static()`) — IPs in a known
   internal range (e.g. `192.168.x.x`) are matched against a hand-maintained
   `static_ranges` config entry, each with a per-octet `zone_map`; everything else
   public-looking is labeled `"public"/"unknown"` immediately, with no DNS
   lookup.
2. **PTR resolution for the dynamic pod range** (e.g. `10.233.x.x`) — these
   addresses churn too fast for a static table, so they go to reverse DNS
   via `resty.dns.resolver` against CoreDNS, parsing the response as either
   `<pod>.<service>.<namespace>.svc.cluster.local.` or
   `<pod>.<namespace>.pod.cluster.local.`.
3. **Caching** — successful lookups are stored in a dedicated `ptr_cache`
   shared dict for `ptr_cache_ttl` seconds. An in-flight lock
   (`ptr_cache:add("inflight:"..ip, ...)`) ensures concurrent requests from
   the same uncached IP trigger one PTR query, not one per request.
4. **Fallback** — unresolved lookups (timeout, no PTR record, malformed
   response) default to `probe_default_service` / `probe_default_namespace`.

**Requirements.**
- CoreDNS must have PTR records available for pod IPs — this is not enabled
  in every cluster's default CoreDNS config and may require an explicit
  `reverse` zone or plugin configuration.
- `resty.dns.resolver` (the `lua-resty-dns` package) must be on `LUA_PATH`.
- A dedicated `ptr_cache` shared dict, sized for your expected number of
  distinct caller IPs within `ptr_cache_ttl`.
- The `static_ranges` config passed into `source_attribution.new_resolver()` is environment-specific and must be kept in sync with
  your actual static IP allocation — it is not auto-discovered.

**How to verify.**
- Confirm CoreDNS answers PTR queries directly:
  `dig -x <pod-ip> @<coredns-cluster-ip>` should return a `PTR` record in
  the expected `<pod>.<service>.<namespace>.svc.cluster.local.` shape.
- Check `/metrics` for `source_service`/`source_namespace` label values that
  are real service/namespace names rather than the fallback default —
  a metrics surface dominated by the fallback value usually means PTR
  records aren't configured or the resolver query is timing out.
- Watch `ptr_dns_timeout` misses via the nginx error log. Timeouts should be
  rare in steady state; frequent timeouts point to CoreDNS load or a network
  path issue between the sidecar and CoreDNS.

**Assumptions.**
- Pod IP ranges are stable enough that a hardcoded prefix check reliably
  routes the right addresses to PTR resolution instead of the static table.
- CoreDNS's PTR response format matches the two patterns this code parses.
  A different DNS naming convention (custom CoreDNS config, different CNI)
  will silently fail to parse and fall through to the default.
- The static `static_ranges` config reflects a *current* and *complete*
  picture of your non-pod internal ranges — a stale table causes segments of
  internal traffic to fall through to reverse DNS or the public bucket
  unnecessarily.

**Keeping it updated.**
- Update `static_ranges` whenever static internal IP ranges change
  (new environment, subnet reallocation, decommissioned range).
- Re-verify the pod-CIDR prefix check after any cluster network change.
- If CoreDNS's PTR record format changes (version upgrade, config change),
  re-test the two `ptrdname` match patterns in the PTR-parsing block.

---

## 5. Waypoint / XFCC identity override

**What it is.** When a service mesh waypoint proxy sits between the caller
and this sidecar, the caller's real identity is recovered from the
mTLS-verified `X-Forwarded-Client-Cert` (XFCC) header instead of trusting the
waypoint's own source IP.

**Why.** In a mesh with per-namespace waypoints, the waypoint terminates and
re-originates the connection, so PTR resolution (section 4) only ever
resolves the *waypoint's* identity, not the original caller's. Without this
override, every request routed through a waypoint would be misattributed to
the waypoint service itself.

**How it works.** After the PTR/static classification in section 4
completes, if the resolved `source_service` equals `cfg.waypoint_service_name`,
the code parses the `X-Forwarded-Client-Cert` header for a SPIFFE URI
(`spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>`) and, if
found, overwrites `source_service`/`source_namespace` with the values from
that identity instead.

**Requirements.**
- A service mesh (the example assumes Istio ambient mode) with waypoints
  deployed per namespace.
- The waypoint must attach a trustworthy, mTLS-verified XFCC header to
  traffic it forwards.
- `waypoint_service_name` in `cfg` must exactly match the Kubernetes Service
  name your mesh's waypoint Gateway creates.

**How to verify.** Send a request through a waypoint from a known
service/namespace and confirm `source_service`/`source_namespace` in
`/metrics` show the *original* caller, not the waypoint's own name.

**Assumptions — read carefully, this is a trust boundary.**
- The override only fires *after* independently confirming (via PTR) that
  the direct peer really is the waypoint. This is deliberate: trusting an
  XFCC header from an arbitrary, unverified peer would let any caller spoof
  their reported identity by simply setting that header themselves. If your
  mesh setup allows XFCC headers to reach this sidecar from a path that
  *isn't* verified mTLS termination at the waypoint, this override becomes
  a spoofing vector.
- SPIFFE ID format is assumed to be
  `spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>`. A different
  identity format (different SPIFFE profile, different mesh product) will
  not match, and the override silently won't apply.

**Keeping it updated.** Re-verify this logic after any mesh version upgrade
or change to how waypoints are deployed — a change in header name, trust
model, or SPIFFE ID format breaks this silently (falls back to
waypoint-as-caller, not an error).

---

## 6. Gauge expiry

**What it is.** A recurring timer that zeroes out gauge metrics (latency,
request/response size, connection requests/time) that haven't been updated
within `expiry_window` seconds, for a given label combination.

**Why.** Counters are naturally quiet when nothing happens. Gauges are not —
a gauge set once and never touched again reports that stale value forever,
which is actively misleading for a low-traffic route ("last observed latency:
2.3s" from six hours ago looks like an ongoing problem).

**How it works.** Every gauge write is paired with a timestamp written to a
shared dict (`custom_metrics`), keyed by metric scope (`"req|"` or `"conn|"`)
plus the label values. A recurring `ngx.timer.at(5, ...)` scans up to
`expiry_scan_limit` keys, and any key untouched for longer than
`expiry_window` seconds has its corresponding gauges set to `0` and its
tracking key deleted.

One expiry marker is shared across all gauges in the same scope
(all request-level gauges share one `"req|..."` marker; both connection-level
gauges share one `"conn|..."` marker) — written once per request regardless
of which individual metrics are enabled, so that disabling one metric in that
scope doesn't prevent the others from expiring correctly.

**Requirements.** A shared dict (`custom_metrics`) sized for your label
cardinality × scope count. `expiry_scan_limit` must be set high enough to
cover a full sweep of active keys in one pass; too low and the scan takes
multiple 5-second cycles to work through a cardinality spike, delaying
expiry.

**How to verify.** Stop traffic to a specific route/label combination and
confirm its gauge value drops to `0` in `/metrics` within roughly
`expiry_window + 5` seconds, rather than staying at its last reported value
indefinitely.

**Assumptions.** `expiry_scan_limit` is large enough relative to actual label
cardinality that the scan isn't perpetually behind. Under a genuine
cardinality explosion, this timer becomes a symptom detector, not a fix —
the sanitization in sections 1–3 is what should be keeping cardinality
bounded in the first place.

**Keeping it updated.** If label cardinality grows (new labels enabled, new
services onboarded), increase `expiry_scan_limit` proportionally and confirm
the 5-second timer still completes a full pass comfortably within that
interval.

---

## 7. Connection-level metrics

**What it is.** `nginx_connection_requests` (requests per connection) and
`nginx_connection_time_seconds` (connection lifetime), each independently
available as a gauge, a histogram, or both, labeled only by `app`/`namespace`
— not by method/route/status, since a single connection can carry multiple
requests.

**Why.** Request-scoped metrics say nothing about connection reuse or
lifetime — useful for diagnosing keep-alive behavior, client connection
churn, or unexpectedly short-lived connections, none of which are visible
from per-request metrics alone.

**How it works.** Reads `$connection_requests` and `$connection_time` nginx
variables per request, applies them to the configured gauge/histogram
objects, and shares the same expiry mechanism as section 6 under a separate
`"conn|"` key namespace so it doesn't interfere with request-scoped expiry.

**Requirements.** None beyond the shared dicts already required by section 6.

**How to verify.** Confirm `nginx_connection_requests` values are `>1` on
connections known to be reusing keep-alive, and that both connection metrics
expire (see section 6) when a connection closes and stays closed.

**Assumptions.** `app`/`namespace` are sufficient labels for your use case.
If you need per-route connection behavior, this metric family would need
restructuring — deliberately not done here to avoid adding cardinality to a
connection-scoped metric.

**Keeping it updated.** No dependency on external state; revisit only if you
need finer-grained labels.

---

## 8. Forward proxy (egress visibility)

**What it is.** A second, loopback-only nginx `server` block
(`127.0.0.1:3128`) that acts as an HTTP/HTTPS forward proxy for the
application container's outbound traffic, sharing the same metrics pipeline
via the `mode` label (`0` = inbound/reverse-proxy, `1` = outbound/forward-proxy).

**Why.** Reverse-proxy metrics only cover traffic arriving at the service.
Outbound calls to other services or third-party APIs otherwise have no
metrics or logs at all. Reusing the existing sidecar avoids deploying a
second piece of infrastructure just for egress.

**How it works.** The application container is configured with
`HTTP_PROXY`/`HTTPS_PROXY` environment variables pointing at
`127.0.0.1:3128`; any HTTP client that respects those variables routes
outbound calls through this block automatically, with no code change. HTTP
requests are logged and metered in full (method, host, path, status,
timing). HTTPS requests arrive as a `CONNECT host:port` and, since TLS
remains end-to-end encrypted, only `host:port` is visible — route and method
labels don't apply to HTTPS traffic.

Handling `CONNECT` requires `ngx_http_proxy_connect_module`, which isn't
included in stock nginx or stock OpenResty and must be compiled in via a
patched build (patching the `docker-openresty` build with
`ngx_http_proxy_connect_module`, matched to the exact nginx core version in
that OpenResty release).

**Requirements.**
- An OpenResty image patched at build time with
  `ngx_http_proxy_connect_module` — the patch file must match the exact
  nginx core version bundled in that OpenResty release, or the build fails.
  Build it by cloning [docker-openresty](https://github.com/openresty/docker-openresty)
  and passing the module in via build args:

  ```
  docker build \
    --build-arg RESTY_VERSION="1.27.1.2" \
    --build-arg RESTY_ADD_PACKAGE_BUILDDEPS="git patch" \
    --build-arg RESTY_EVAL_PRE_CONFIGURE="cd /tmp && git clone https://github.com/chobits/ngx_http_proxy_connect_module.git" \
    --build-arg RESTY_CONFIG_OPTIONS_MORE="--add-module=/tmp/ngx_http_proxy_connect_module" \
    --build-arg RESTY_EVAL_PRE_MAKE="cd /tmp/openresty-1.27.1.2 && patch -d build/nginx-1.27.1 -p1 < /tmp/ngx_http_proxy_connect_module/patch/proxy_connect_rewrite_102101.patch" \
    -f alpine/Dockerfile \
    -t your-registry/openresty:1.27.1.2-egress-0.1 \
    .
  ```

  This clones the module, patches it against the exact nginx core bundled in
  that `RESTY_VERSION`, and compiles it in. The patch filename
  (`proxy_connect_rewrite_102101.patch` above) must match the nginx core
  version — check `ngx_http_proxy_connect_module`'s `patch/` directory for
  the right one before building, and re-check it on every `RESTY_VERSION`
  bump; a mismatch fails the build rather than failing silently.
- `resolver` in the proxy `server` block must point at the real, current
  CoreDNS ClusterIP for that cluster (not portable across clusters — fetch
  it explicitly per environment, e.g.
  `kubectl get svc -n kube-system -l k8s-app=kube-dns -o jsonpath='{.spec.clusterIP}'`).
- `NO_PROXY` on the application container should include internal-only
  destinations (`.svc.cluster.local`, internal domains) so purely internal
  calls don't route through the proxy unnecessarily.

**How to verify.**
- Validate the patched build itself: run the built image and confirm
  `openresty -V` lists `ngx_http_proxy_connect_module` in its configure
  arguments, then validate your actual config against it:
  `openresty -t -c /path/to/this/default.conf`.
- From inside the application container, confirm an outbound HTTPS call
  produces a `CONNECT host:port` entry in the proxy's access log, and an
  outbound HTTP call produces a full entry with method/status/timing.
- Confirm `mode="1"` requests appear in `/metrics` alongside `mode="0"`
  requests, and that route/method labels are absent or generic for HTTPS
  entries specifically.

**Assumptions.**
- The application's HTTP client(s) honor `HTTP_PROXY`/`HTTPS_PROXY`
  environment variables natively — most mainstream HTTP libraries do, but
  this should be confirmed per language/runtime rather than assumed.
- Real HTTPS payload visibility is explicitly out of scope. Getting it would
  require terminating and re-establishing TLS (a MITM setup), which is a
  materially heavier security decision this proxy does not make.
- `proxy_connect_allow` is set to `all` here deliberately, not `443` only:
  outbound TLS traffic in this environment isn't confined to port 443, so
  restricting `CONNECT` to 443 would silently break egress to any service
  listening on a different TLS port. `proxy_connect_allow` only gates which
  ports `CONNECT` (i.e. HTTPS tunnel establishment) may target — it has no
  effect on plain HTTP requests, which are already handled by the same
  `location /` block via `proxy_pass` regardless of this setting. If your
  environment's outbound TLS traffic *is* confined to 443, restricting this
  to `443` narrows what the proxy can be used for; if it isn't, `all` is the
  correct setting, not an oversight.

**Keeping it updated.**
- Every OpenResty version bump requires re-checking
  `ngx_http_proxy_connect_module`'s `patch/` directory for a matching patch
  file before rebuilding — a version mismatch fails the build, not silently.
- Re-verify the CoreDNS ClusterIP after any cluster network change; a stale
  `resolver` value breaks outbound proxying silently (existing DNS cache
  entries keep working until they expire, then resolution fails).
- Treat `resolver` health as a monitored dependency, not a set-and-forget
  value — a dedicated health check on outbound connectivity through this
  proxy is worth adding separately.

---

## Known issue corrected in this fork

The upstream copy of this config set connection-metric labels in the
`location = /metrics` block to hardcoded string literals that had drifted
from the `cfg.app` / `cfg.namespace` values used everywhere else in the
file — meaning the `/metrics` endpoint's own connection counters were
reported under a different label pair than the request-driven connection
metrics elsewhere in the same file, silently splitting what should be one
time series into two. This fork reads `cfg.app`/`cfg.namespace` consistently
instead. If you maintain copies of this config elsewhere, check for the same
divergence.

---

## Using this fork

### Option A: just the metrics library (no fork-specific additions)

If you only want the upstream `nginx-lua-prometheus` behavior, this fork
works exactly like upstream — none of the core files are modified. Point
`lua_package_path` at the repo root and use the library directly:

```nginx
lua_shared_dict prometheus_metrics 10M;
lua_package_path "/path/to/this/repo/?.lua;;";

init_worker_by_lua_block {
  prometheus = require("prometheus").init("prometheus_metrics")
  metric_requests = prometheus:counter(
    "nginx_http_requests_total", "Number of HTTP requests", {"host", "status"})
}

log_by_lua_block {
  metric_requests:inc(1, {ngx.var.server_name, ngx.var.status})
}
```

See the upstream `README.md` above for the full API (`counter`, `gauge`,
`histogram`, `collect`).

### Option B: the full sidecar example (this fork's additions)

To use the `lib/` modules — route sanitization, host classification, caller
identification, gauge expiry, or all of them together as in
`examples/openresty-sidecar/default.conf` — add `lib/` to your
`lua_package_path` alongside the repo root:

```nginx
lua_package_path "/path/to/this/repo/?.lua;/path/to/this/repo/lib/?.lua;;";
```

Then either:

- **Use the modules individually** in your own config — each one is
  independent and documented above (sections 1–7). For example, to add
  just route sanitization to an existing setup:

  ```lua
  -- in log_by_lua_block, before building your labels
  local route_sanitizer = require("route_sanitizer")
  local route = route_sanitizer.sanitize(ngx.var.request_uri)
  ```

- **Use the full reference config** as a starting point: copy
  `examples/openresty-sidecar/default.conf`, replace every placeholder
  value (`example-app`, `example-namespace`, the `static_ranges` zone map,
  `ptr_dns_server`, `cluster_ip_prefix`) with your own, and drop `prometheus.lua`,
  `prometheus_keys.lua`, `prometheus_resty_counter.lua`, and `lib/*.lua`
  onto the path configured in `lua_package_path`. If you also want the
  forward-proxy leg (section 8), build the patched OpenResty image first
  using the `docker build` command in that section.

Either way, `/metrics` (or whatever endpoint you wire `prometheus:collect()`
into) should start returning labeled series immediately — no additional
build step is needed for the Lua side, since nginx/OpenResty loads `.lua`
files directly from `lua_package_path` at request time.
