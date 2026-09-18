# Fork notes

This is a fork of
[knyar/nginx-lua-prometheus](https://github.com/knyar/nginx-lua-prometheus),
a Prometheus metrics library for Nginx written in Lua, MIT licensed. Credit
for the library itself — `prometheus.lua`, `prometheus_keys.lua`,
`prometheus_resty_counter.lua`, and the counter/gauge/histogram API —
belongs entirely to the upstream project. **None of those files are
modified here**, so upstream releases still pull in cleanly.

What this fork adds on top is a reference sidecar deployment:

- **`lib/`** — nine small Lua modules. Six are pure logic with no
  environment-specific values (`route_sanitizer`, `host_classifier`,
  `client_subnet`, `gauge_expiry`, `source_attribution`, `app_toggle`),
  kept unit-testable without a running nginx worker. `http_metrics.lua` and
  `stream_metrics.lua` wire all of that into the `prometheus` API. And
  `metrics_config.lua` is plain data — the one file here you're meant to
  edit per deployment.
- **`examples/openresty-sidecar/`** — `default.conf` (HTTP) and
  `stream.conf` (TCP/UDP) show it all wired up; `nginx.conf` ties them
  together; `k8s/` has a runnable, mock-data ConfigMaps + Deployment +
  Service/ServiceMonitor example.

Tests live in `tests/*_test.lua` (one per pure module, using `luaunit` like
upstream's own `prometheus_test.lua`):

```
luarocks install luaunit
for f in tests/*_test.lua; do lua5.1 "$f" || exit 1; done
```

## What each piece does

| Piece | Module | Needs a running nginx worker? |
|---|---|---|
| Route sanitization | `route_sanitizer.lua` | No |
| Client subnet masking | `client_subnet.lua` | No |
| Host classification | `host_classifier.lua` | No |
| Caller identification (`source_service`/`source_namespace`) | `source_attribution.lua` | Only the DNS-resolving part |
| Waypoint / XFCC override | `source_attribution.lua` | No |
| Gauge expiry | `gauge_expiry.lua` | Only `:start()` |
| Per-app metrics toggle | `app_toggle.lua` | No |
| HTTP metrics + forward proxy | `http_metrics.lua` + `default.conf` | Yes |
| Stream (TCP/UDP) metrics | `stream_metrics.lua` + `stream.conf` | Yes |
| Everything's config | `metrics_config.lua` | No — just data |

### Keeping request/response labels low-cardinality

Three small modules exist purely to stop labels from exploding into one
time series per request:

- **`route_sanitizer.sanitize()`** collapses path segments that look like
  IDs — pure numbers, UUIDs, hex tokens, slugs with a trailing digit, long
  alphanumeric tokens, file extensions — into `$param`, so
  `/orders/8231/items/9f8a3c2e-...` becomes `/orders/$param/items/$param`.
  Each check is independently toggleable in `metrics_config.lua`. If a new
  ID convention shows up that none of the checks catch, add a check rather
  than turning sanitization off.
- **`client_subnet.mask()`** truncates an IPv4 address to a `/24` (private
  ranges) or `/16` (public) before it's used as a label — e.g. `10.233.4.17`
  → `10.233.4.0`. IPv6 and unparseable input return `"unknown"`. Off by
  default (`label_client_subnet = false`); the caller-identification labels
  below are usually more useful.
- **`host_classifier.classify()`** turns the `Host` header — fully
  client-controlled — into `"localhost"`, `"kubernetes"` (matched against
  `cluster_ip_prefix`), a generic `"$ip"`, or the real hostname unchanged.
  Get `cluster_ip_prefix` wrong and internal IPs just fall into the generic
  `"$ip"` bucket — harmless, just less informative.

### Caller identification

**`source_attribution.lua`** labels every inbound request with *who called
it*, not just what happened — resolved in order: a hand-maintained
`static_ranges` table for known internal subnets, then reverse-DNS (PTR)
against CoreDNS for the dynamic pod range (cached in a shared dict, with an
in-flight lock so a burst of requests from one uncached IP doesn't fire a
PTR query per request), then a configured fallback if nothing resolves.
Needs CoreDNS to actually have PTR records for pod IPs (not on by default in
every cluster) and `resty.dns.resolver` on `LUA_PATH`.

**Waypoint override.** If you run a service mesh with per-namespace
waypoints (the example assumes Istio ambient mode), a waypoint terminates
and re-originates the connection, so PTR alone only ever resolves to *the
waypoint*, not the real caller. When the resolved caller is the waypoint,
`apply_waypoint_override()` recovers the real identity from the SPIFFE URI
in the mTLS-verified `X-Forwarded-Client-Cert` header instead.

> ⚠️ **This is a trust boundary.** The override only fires once PTR has
> independently confirmed the direct peer really *is* the waypoint —
> trusting an XFCC header from an unverified peer would let any caller
> spoof its reported identity just by setting that header itself. If your
> mesh can let XFCC reach this sidecar from anywhere other than verified
> mTLS termination at the waypoint, this becomes a spoofing vector.

### Gauges that don't go stale

Prometheus gauges don't self-expire — a gauge set once and never touched
again reports that value forever, which is actively misleading for a
low-traffic route. **`gauge_expiry.lua`** pairs every gauge write with a
timestamp in a shared dict; a 5-second timer sweeps for label combinations
untouched for `expiry_window` seconds and zeroes their gauges. It's used for
request-level gauges (latency, request/response size), connection-level
gauges (`nginx_connection_requests`, `nginx_connection_time_seconds`), and
— on the stream side — the two "last observed value" gauges
(`upstream_connect_time`, `session_duration`). Same module, three call
sites, each with its own shared dict.

If cardinality grows a lot, raise `expiry_scan_limit` so the 5-second sweep
still completes one full pass — but treat that as a symptom, not a fix; the
sanitization modules above are what should be keeping cardinality bounded
in the first place.

### Forward proxy (egress visibility)

A second, loopback-only `server{}` block (`127.0.0.1:3128`) turns this
sidecar into an HTTP/HTTPS forward proxy for the app container's *outbound*
traffic, sharing the same metrics pipeline via the `mode` label (`0` =
inbound, `1` = outbound). Point `HTTP_PROXY`/`HTTPS_PROXY` at it and any
compliant HTTP client routes through automatically. Plain HTTP gets full
method/route/status/timing; HTTPS arrives as `CONNECT host:port` and, since
TLS stays end-to-end encrypted, only the `host:port` is visible — that's a
deliberate scope limit, not a bug: real payload visibility would need a MITM
TLS termination, a much heavier security decision this proxy doesn't make.

Handling `CONNECT` needs `ngx_http_proxy_connect_module`, which isn't in
stock nginx/OpenResty — build it in:

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

The patch filename must match the nginx core version bundled in
`RESTY_VERSION` — check `ngx_http_proxy_connect_module`'s `patch/` directory
for the right one, and re-check on every version bump; a mismatch fails the
build outright rather than silently.

> ⚠️ `proxy_connect_allow all` is deliberate, not an oversight: it only
> gates which ports `CONNECT` (HTTPS tunneling) may target, and outbound TLS
> in this environment isn't confined to port 443. Narrowing it to `443`
> would silently break egress to anything listening on another TLS port —
> only do that if your environment's outbound TLS genuinely never leaves 443.

### Stream (TCP/UDP) proxy metrics

`stream.conf` / `stream_metrics.lua` is the stream-module counterpart to
the above, for anything proxied at the TCP/UDP layer (Redis in the
example): connection counts, bytes sent/received, session duration, and
upstream connect-time/first-byte-time. It keeps its own Prometheus registry
on its own port (`:9254`) rather than sharing the HTTP side's `/metrics`,
because nginx can't share a shared dict between the http and stream modules
(see upstream's own [Usage in stream
module](README.md#usage-in-stream-module) note). Each destination gets its
own `server{}` block with `set $destination_name "..."`, feeding both the
`destination` label and the per-app toggle below; needs
`ngx_stream_lua_module` (stock in OpenResty) and its own Prometheus scrape
job.

### Per-app metrics toggle

`app_toggle.enabled(apps, key)` lets you turn off metrics for one leg of
traffic — the forward-proxy leg (`apps.forward_proxy`) or one stream
destination (`apps.stream.<name>`) — without touching the traffic itself.
No entry, or an entry without `metrics_enabled = false`, means enabled: this
is opt-out, not opt-in, so a new destination gets metrics by default.

---

## Known issue corrected in this fork

Upstream's version of this config hardcoded the `/metrics` endpoint's own
connection-metric labels as string literals that had drifted from the
`app`/`namespace` values used everywhere else — silently splitting one
time series into two. This fork reads them from `metrics_config.lua`
consistently instead. If you maintain copies of this config elsewhere,
check for the same drift.

---

## Using this fork

**Just the library, no additions** — this fork behaves exactly like
upstream; point `lua_package_path` at the repo root and use `prometheus.lua`
directly. See the upstream `README.md` above for the full API.

**The full sidecar example** — add `lib/` to `lua_package_path` alongside
the repo root, then either pull in one module you want (they're all
independent — e.g. `require("route_sanitizer").sanitize(ngx.var.request_uri)`
in your own `log_by_lua_block`), or copy `default.conf`/`stream.conf`
as-is and edit `lib/metrics_config.lua` for your environment (app/namespace
names, `static_ranges`, `ptr_dns_server`, `cluster_ip_prefix`). Build the
patched OpenResty image first if you want the forward-proxy leg.

**As a Kubernetes sidecar** — `examples/openresty-sidecar/k8s/` has a
complete, mock-data example: ConfigMaps for `nginx.conf`/`default.conf`/
`stream.conf`/`metrics_config.lua`, a Deployment showing the app+nginx
container pair, and a Service/ServiceMonitor exposing both metrics
endpoints. Replace every mock name, image, and label before applying.

Either way, `/metrics` starts returning labeled series immediately — nginx
loads `.lua` files from `lua_package_path` at request time, no build step
needed for the Lua side.

---

## Fork changelog

Dated entries for this fork's own additions. Upstream's `CHANGELOG.md` is
unaffected — none of its files are touched here.

### 2026-09-18

- Added `lib/app_toggle.lua`, wired into `default.conf` (forward-proxy leg)
  and `stream.conf` (per-destination).
- Added `examples/openresty-sidecar/stream.conf`: full TCP/UDP proxy
  metrics, reusing `lib/gauge_expiry.lua`.
- Added `examples/openresty-sidecar/nginx.conf` and
  `examples/openresty-sidecar/k8s/` (mock-data ConfigMaps, a sample sidecar
  Deployment, a Service/ServiceMonitor pair) so the example deploys
  end-to-end instead of just being read.
- Restructured `default.conf`/`stream.conf` down to wiring + `server{}`
  blocks only (397 → 91 and 231 → 60 lines). Added `lib/metrics_config.lua`
  (all environment-specific values) and `lib/http_metrics.lua`/
  `lib/stream_metrics.lua` (the orchestration that used to be inline,
  now proper modules built on the existing pure `lib/` modules).
