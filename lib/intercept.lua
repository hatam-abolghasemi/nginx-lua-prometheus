-- intercept.lua
-- Decides, per CONNECT, whether the forward proxy should TLS-intercept it
-- (hand it to the :3129 terminator) or tunnel it straight through. All the
-- machinery -- this module, the :3129 server, the shared dict -- is baked into
-- the image; a deployment turns interception on with one env var and a mounted
-- CA, nothing else.
--
-- Switches (declared for workers in /etc/nginx/main.d/intercept-env.conf):
--   INTERCEPT_TLS        "on" to enable; anything else (or unset) = off.
--   INTERCEPT_TLS_PORTS  comma list of TLS ports to intercept; default "443".
--   INTERCEPT_BYPASS     comma list of hosts to never intercept (mTLS/pinning).
--
-- Off by default: with INTERCEPT_TLS unset, should() is always false, so the
-- proxy behaves exactly as a plain CONNECT passthrough and :3129 never sees
-- traffic. Values are read once per worker (env is fixed for the process).

local _M = {}

local conf  -- memoised { enabled=bool, ports={["443"]=true,...}, bypass={host=true} }

local function parse_set(csv, default_csv)
    local out = {}
    local s = csv
    if not s or s == "" then s = default_csv end
    if s then
        for item in s:gmatch("[^,%s]+") do out[item] = true end
    end
    return out
end

local function config()
    if conf then return conf end
    conf = {
        enabled = (os.getenv("INTERCEPT_TLS") == "on"),
        ports   = parse_set(os.getenv("INTERCEPT_TLS_PORTS"), "443"),
        bypass  = parse_set(os.getenv("INTERCEPT_BYPASS"), nil),
    }
    return conf
end

-- True when the current request is a CONNECT we should decrypt. Reads only
-- nginx vars that exist for a CONNECT (request_method, host, request_port),
-- so it is safe to call in any phase, including log_by_lua.
function _M.should()
    local c = config()
    if not c.enabled then return false end
    if ngx.var.request_method ~= "CONNECT" then return false end
    local host = ngx.var.host or ""
    if c.bypass[host] then return false end
    return c.ports[ngx.var.request_port or ""] == true
end

-- Tunnel target for the forward proxy's `tunnel_pass`: the local terminator
-- when intercepting, otherwise the real CONNECT target (same as a bare
-- `tunnel_pass;`).
function _M.upstream()
    if _M.should() then
        return "127.0.0.1:3129"
    end
    return (ngx.var.host or "") .. ":" .. (ngx.var.request_port or "443")
end

return _M