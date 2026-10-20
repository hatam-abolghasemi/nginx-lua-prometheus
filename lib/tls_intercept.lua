-- tls_intercept.lua
-- Per-SNI leaf-certificate minting for the forward-proxy's HTTPS interception
-- leg (the 127.0.0.1:3129 server in default.conf). On each TLS handshake it
-- mints -- and caches -- a short-lived leaf certificate for the requested SNI,
-- signed by a CA that is mounted into THIS container only (never the app's).
-- That lets the :3129 server terminate the app's outbound TLS, read the real
-- method/route/status for metrics, and re-originate a verified TLS connection
-- to the true destination.
--
-- Wired from default.conf as:
--   ssl_certificate_by_lua_block { require("tls_intercept").mint() }
--
-- Requires lua-resty-openssl (bundled in OpenResty) and ngx.ssl. Nothing here
-- runs unless a request actually reaches :3129, i.e. unless interception is
-- switched on by mounting an /etc/nginx/intercept/ports/*.map entry -- so the
-- default image never loads a CA and behaves exactly as a plain proxy.
--
-- The CA is a trust anchor: whoever holds its key can impersonate any host to
-- every pod that trusts it. Use a dedicated CA (ideally one per namespace),
-- keep the key in a Secret mounted only here, and tightly scope RBAC on it.

local ssl     = require("ngx.ssl")
local pkey    = require("resty.openssl.pkey")
local x509    = require("resty.openssl.x509")
local name    = require("resty.openssl.x509.name")
local altname = require("resty.openssl.x509.altname")
local bn      = require("resty.openssl.bn")

local ok_cfg, config = pcall(require, "metrics_config")
local ic = (ok_cfg and config and config.intercept) or {}

local CA_CERT_PATH = ic.ca_cert_path or "/etc/nginx/intercept/ca.crt"
local CA_KEY_PATH  = ic.ca_key_path  or "/etc/nginx/intercept/ca.key"
local CERT_TTL     = tonumber(ic.cert_ttl) or 86400
local LEAF_BITS    = tonumber(ic.leaf_bits) or 2048

local _M = {}

-- Per-worker memoised state: the CA pair, one reusable leaf key shared by every
-- minted cert (as mitmproxy does -- a per-host key buys nothing here), and the
-- shared-dict cache of already-minted leaves.
local ca_cert, ca_key, leaf_key
local cache = ngx.shared.ssl_mint_cache

local function read_file(path)
    local f, err = io.open(path, "r")
    if not f then return nil, err end
    local data = f:read("*a")
    f:close()
    return data
end

-- Load the CA and generate the shared leaf key once per worker. Returns
-- false (logged) if the CA isn't mounted, so a misconfigured deploy fails the
-- handshake loudly rather than silently serving the baked fallback cert.
local function ensure_ca()
    if ca_cert and ca_key and leaf_key then return true end

    local cert_pem, cerr = read_file(CA_CERT_PATH)
    if not cert_pem then
        ngx.log(ngx.ERR, "tls_intercept: cannot read CA cert at ", CA_CERT_PATH, ": ", cerr)
        return false
    end
    local key_pem, kerr = read_file(CA_KEY_PATH)
    if not key_pem then
        ngx.log(ngx.ERR, "tls_intercept: cannot read CA key at ", CA_KEY_PATH, ": ", kerr)
        return false
    end

    local c, e1 = x509.new(cert_pem)
    if not c then ngx.log(ngx.ERR, "tls_intercept: parse CA cert: ", e1); return false end
    local k, e2 = pkey.new(key_pem)
    if not k then ngx.log(ngx.ERR, "tls_intercept: parse CA key: ", e2); return false end
    local lk, e3 = pkey.new({ type = "RSA", bits = LEAF_BITS })
    if not lk then ngx.log(ngx.ERR, "tls_intercept: generate leaf key: ", e3); return false end

    ca_cert, ca_key, leaf_key = c, k, lk
    return true
end

-- Build and sign a leaf for `host`; returns cert PEM and key PEM.
local function mint_leaf(host)
    local crt, err = x509.new()
    if not crt then return nil, nil, err end

    crt:set_version(3)
    crt:set_serial_number(bn.new(math.floor(ngx.now() * 1000) % 2147483647))
    crt:set_not_before(ngx.time() - 300)
    crt:set_not_after(ngx.time() + CERT_TTL)
    crt:set_pubkey(leaf_key)

    local subj = name.new()
    subj:add("CN", host)
    crt:set_subject_name(subj)
    crt:set_issuer_name(ca_cert:get_subject_name())

    local alt = altname.new()
    alt:add("DNS", host)
    crt:set_subject_alt_name(alt)

    local ok_sign, serr = crt:sign(ca_key)
    if not ok_sign then return nil, nil, serr end

    return crt:to_PEM(), leaf_key:to_PEM("private")
end

local function get_or_mint(host)
    local cached = cache:get(host)
    if cached then
        local sep = cached:find("\0", 1, true)
        if sep then
            return cached:sub(1, sep - 1), cached:sub(sep + 1)
        end
    end

    local cert_pem, key_pem, err = mint_leaf(host)
    if not cert_pem then return nil, nil, err end

    -- Expire a little before the cert does so we never serve a stale one.
    cache:set(host, cert_pem .. "\0" .. key_pem, CERT_TTL - 60)
    return cert_pem, key_pem
end

function _M.mint()
    local host, err = ssl.server_name()
    if not host or host == "" then
        -- No SNI: fall back to the baked ssl_certificate. Can't verify or
        -- name an upstream without a host anyway.
        ngx.log(ngx.WARN, "tls_intercept: handshake with no SNI: ", err)
        return
    end

    if not ensure_ca() then
        return  -- keeps the baked fallback cert; upstream verify will still fail safely
    end

    local cert_pem, key_pem, merr = get_or_mint(host)
    if not cert_pem then
        ngx.log(ngx.ERR, "tls_intercept: mint for ", host, ": ", merr)
        return
    end

    local der_chain, e1 = ssl.cert_pem_to_der(cert_pem)
    local der_key,   e2 = ssl.priv_key_pem_to_der(key_pem)
    if not der_chain or not der_key then
        ngx.log(ngx.ERR, "tls_intercept: pem->der failed: ", e1 or "", " ", e2 or "")
        return
    end

    ssl.clear_certs()
    local ok1, se1 = ssl.set_der_cert(der_chain)
    local ok2, se2 = ssl.set_der_priv_key(der_key)
    if not ok1 or not ok2 then
        ngx.log(ngx.ERR, "tls_intercept: set cert/key failed: ", se1 or "", " ", se2 or "")
    end
end

return _M
