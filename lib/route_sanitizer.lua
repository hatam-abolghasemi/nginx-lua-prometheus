-- route_sanitizer.lua
-- Collapses high-cardinality path segments (IDs, UUIDs, hex tokens, etc.)
-- into a bounded "$param" placeholder so a request URI is safe to use as a
-- Prometheus label without one time series per unique path.
--
-- Pure Lua, no ngx.* dependency: usable and testable outside of an nginx
-- worker.
--
-- Usage:
--   local route_sanitizer = require("route_sanitizer")
--   local route = route_sanitizer.sanitize("/orders/8231/items/9f8a3c2e-...")
--   -- route == "/orders/$param/items/$param"
--
-- All checks are individually toggleable via the second, optional argument:
--   route_sanitizer.sanitize(path, { uuid = false })
-- disables only the UUID check, keeping every other default enabled.

local _M = {}

_M.defaults = {
  pure_numeric      = true,   -- /users/123
  uuid              = true,   -- /users/550e8400-e29b-41d4-a716-446655440000
  hex               = true,   -- /obj/a1b2c3d4e5f6ab
  slug_suffix_digit = true,   -- /zone-7  /order-12345
  long_with_digit   = true,   -- /x/abc123xyz  (len > min_len and has a digit)
  file_extension    = true,   -- /report.pdf  /file.js  /image.png
  min_len           = 4,      -- minimum segment length for the long_with_digit rule
  max_segment_len   = 64,     -- anything longer than this is always $param
}

local UUID_PATTERN =
  "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

local function merge_opts(opts)
  if not opts then return _M.defaults end
  local merged = {}
  for k, v in pairs(_M.defaults) do merged[k] = v end
  for k, v in pairs(opts) do merged[k] = v end
  return merged
end

-- Returns true if a single path segment should be collapsed into "$param".
function _M.is_param_segment(seg, opts)
  local cfg = merge_opts(opts)

  if #seg > cfg.max_segment_len then
    return true
  end
  if cfg.pure_numeric and seg:match("^%d+$") then
    return true
  end
  if cfg.uuid and seg:match(UUID_PATTERN) then
    return true
  end
  if cfg.hex and #seg >= 8 and seg:match("^%x+$") then
    return true
  end
  if cfg.slug_suffix_digit and seg:match("-%d+$") then
    return true
  end
  if cfg.long_with_digit and #seg > cfg.min_len and seg:find("%d") then
    return true
  end
  if cfg.file_extension and seg:match("%.%a%a+$") then
    return true
  end
  return false
end

-- Sanitizes a full request path (query string, if any, must already be
-- stripped by the caller) into a bounded route shape.
function _M.sanitize(path, opts)
  path = path or "/"
  -- strip any query string defensively, collapse duplicate slashes
  path = path:match("^[^?]*"):gsub("//+", "/")

  local segments = {}
  for seg in path:gmatch("[^/]+") do
    if _M.is_param_segment(seg, opts) then
      if segments[#segments] ~= "$param" then
        table.insert(segments, "$param")
      end
    else
      table.insert(segments, seg)
    end
  end

  local route = "/" .. table.concat(segments, "/")
  if #route > 1 and route:sub(-1) == "/" then
    route = route:sub(1, -2)
  end
  return route
end

return _M
