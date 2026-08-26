local boundaries = require("partial_completion.boundaries")
local path_semantics = require("partial_completion.path")

local M = {}

local defaults = {
  limit = 100,
  max_limit = 1000,
  matching_style = "extended",
  categories = {},
  debug = {
    enabled = false,
    sensitive = false,
    max_entries = 200,
    sink = nil,
  },
  native = {
    enabled = false,
    max_items = 10,
    min_width = 20,
    max_width = 80,
    mappings = {
      next = "<Tab>",
      previous = "<S-Tab>",
      accept = "<C-y>",
      cancel = "<C-e>",
    },
    request = {},
  },
  filesystem = {
    branch_limit = 64,
    max_results = 1000,
    max_entries_scanned = 50000,
    scan_chunk_size = 256,
    emit_chunk_size = 32,
    hidden = "matching",
    case_sensitive = nil,
    cache = {
      max_entries = 128,
      max_bytes = 4 * 1024 * 1024,
      ttl_ms = 1000,
    },
  },
}

local max_copy_depth = 72

local function copy(value, ancestors, depth, depth_limit)
  if type(value) ~= "table" then
    return value
  end
  depth = depth or 0
  depth_limit = depth_limit or max_copy_depth
  if depth >= depth_limit then
    error("configuration data exceeds maximum table depth of " .. depth_limit, 3)
  end
  ancestors = ancestors or {}
  if ancestors[value] then
    error("configuration data contains a table cycle", 3)
  end
  ancestors[value] = true
  local result = {}
  for key, child in pairs(value) do
    result[copy(key, ancestors, depth + 1, depth_limit)] = copy(child, ancestors, depth + 1, depth_limit)
  end
  ancestors[value] = nil
  return result
end

local function finite_number(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function positive_integer(value, name)
  if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
    error(name .. " must be a positive integer", 3)
  end
end

local function nonnegative_number(value, name)
  if not finite_number(value) or value < 0 then
    error(name .. " must be a non-negative number", 3)
  end
end

local function reject_unknown(options, allowed, prefix)
  for name in pairs(options) do
    if not allowed[name] then
      error((prefix or "configuration") .. "." .. tostring(name) .. " is unknown", 3)
    end
  end
end

local function dense_array_length(value, name)
  local count = 0
  local maximum = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      error(name .. " must be a dense list", 3)
    end
    count = count + 1
    maximum = math.max(maximum, key)
  end
  if maximum ~= count then
    error(name .. " must be a dense list", 3)
  end
  return count
end

local function resolve_debug(options, resolved)
  if options.debug == nil then
    return
  end
  if type(options.debug) ~= "table" then
    error("debug must be a table", 3)
  end
  reject_unknown(options.debug, {
    enabled = true,
    sensitive = true,
    max_entries = true,
    sink = true,
  }, "debug")
  for _, name in ipairs({ "enabled", "sensitive" }) do
    if options.debug[name] ~= nil then
      if type(options.debug[name]) ~= "boolean" then
        error("debug." .. name .. " must be boolean", 3)
      end
      resolved.debug[name] = options.debug[name]
    end
  end
  if options.debug.max_entries ~= nil then
    positive_integer(options.debug.max_entries, "debug.max_entries")
    resolved.debug.max_entries = options.debug.max_entries
  end
  if options.debug.sink ~= nil and type(options.debug.sink) ~= "function" then
    error("debug.sink must be a function", 3)
  end
  if options.debug.sink ~= nil then
    resolved.debug.sink = options.debug.sink
  end
end

local function resolve_filesystem(options, resolved)
  if options.filesystem == nil then
    return
  end
  if type(options.filesystem) ~= "table" then
    error("filesystem must be a table", 3)
  end
  local filesystem = options.filesystem
  reject_unknown(filesystem, {
    branch_limit = true,
    max_results = true,
    max_entries_scanned = true,
    scan_chunk_size = true,
    emit_chunk_size = true,
    hidden = true,
    case_sensitive = true,
    cache = true,
  }, "filesystem")
  local positive_fields = {
    "branch_limit",
    "max_results",
    "max_entries_scanned",
    "scan_chunk_size",
    "emit_chunk_size",
  }
  for _, name in ipairs(positive_fields) do
    if filesystem[name] ~= nil then
      positive_integer(filesystem[name], "filesystem." .. name)
      resolved.filesystem[name] = filesystem[name]
    end
  end
  if filesystem.hidden ~= nil then
    if filesystem.hidden ~= "matching" and filesystem.hidden ~= "always" and filesystem.hidden ~= "never" then
      error("filesystem.hidden must be matching, always, or never", 3)
    end
    resolved.filesystem.hidden = filesystem.hidden
  end
  if filesystem.case_sensitive ~= nil then
    if type(filesystem.case_sensitive) ~= "boolean" then
      error("filesystem.case_sensitive must be boolean", 3)
    end
    resolved.filesystem.case_sensitive = filesystem.case_sensitive
  end
  if filesystem.cache ~= nil then
    if type(filesystem.cache) ~= "table" then
      error("filesystem.cache must be a table", 3)
    end
    reject_unknown(filesystem.cache, {
      max_entries = true,
      max_bytes = true,
      ttl_ms = true,
    }, "filesystem.cache")
    for _, name in ipairs({ "max_entries", "max_bytes" }) do
      if filesystem.cache[name] ~= nil then
        positive_integer(filesystem.cache[name], "filesystem.cache." .. name)
        resolved.filesystem.cache[name] = filesystem.cache[name]
      end
    end
    if filesystem.cache.ttl_ms ~= nil then
      nonnegative_number(filesystem.cache.ttl_ms, "filesystem.cache.ttl_ms")
      resolved.filesystem.cache.ttl_ms = filesystem.cache.ttl_ms
    end
  end
end

local function resolve_native(options, resolved)
  if options.native == nil then
    return
  end
  if type(options.native) ~= "table" then
    error("native must be a table", 3)
  end
  local native = options.native
  reject_unknown(native, {
    enabled = true,
    max_items = true,
    min_width = true,
    max_width = true,
    request = true,
    mappings = true,
  }, "native")
  if native.enabled ~= nil then
    if type(native.enabled) ~= "boolean" then
      error("native.enabled must be boolean", 3)
    end
    resolved.native.enabled = native.enabled
  end
  for _, name in ipairs({ "max_items", "min_width", "max_width" }) do
    if native[name] ~= nil then
      positive_integer(native[name], "native." .. name)
      resolved.native[name] = native[name]
    end
  end
  if resolved.native.min_width > resolved.native.max_width then
    error("native.min_width must not exceed native.max_width", 3)
  end
  if native.request ~= nil then
    if type(native.request) ~= "table" then
      error("native.request must be a table", 3)
    end
    reject_unknown(native.request, {
      allow_subsequence = true,
      case_mode = true,
      cwd = true,
      env = true,
      filesystem_case_sensitive = true,
      home = true,
      limit = true,
      matching_style = true,
      platform = true,
      search_roots = true,
    }, "native.request")
    local request = native.request
    if request.allow_subsequence ~= nil and type(request.allow_subsequence) ~= "boolean" then
      error("native.request.allow_subsequence must be boolean", 3)
    end
    if
      request.case_mode ~= nil
      and request.case_mode ~= "sensitive"
      and request.case_mode ~= "insensitive"
      and request.case_mode ~= "smart"
      and request.case_mode ~= "filesystem"
    then
      error("native.request.case_mode is invalid", 3)
    end
    if request.matching_style ~= nil and request.matching_style ~= "extended" and request.matching_style ~= "emacs" then
      error("native.request.matching_style is invalid", 3)
    end
    if request.limit ~= nil then
      positive_integer(request.limit, "native.request.limit")
    end
    if request.platform ~= nil and request.platform ~= "posix" and request.platform ~= "windows" then
      error("native.request.platform must be posix or windows", 3)
    end
    for _, name in ipairs({ "cwd", "home" }) do
      local value = request[name]
      if value ~= nil and (type(value) ~= "string" or not path_semantics.is_absolute(value, request.platform)) then
        error("native.request." .. name .. " must be an absolute path", 3)
      end
    end
    if request.env ~= nil then
      if type(request.env) ~= "table" then
        error("native.request.env must be a string table", 3)
      end
      for name, value in pairs(request.env) do
        if type(name) ~= "string" or type(value) ~= "string" then
          error("native.request.env must be a string table", 3)
        end
      end
    end
    if request.search_roots ~= nil then
      if type(request.search_roots) ~= "table" then
        error("native.request.search_roots must be a list of paths", 3)
      end
      local count = dense_array_length(request.search_roots, "native.request.search_roots")
      for index = 1, count do
        local value = request.search_roots[index]
        if type(value) ~= "string" or value == "" then
          error("native.request.search_roots[" .. index .. "] must be a non-empty string", 3)
        end
      end
    end
    local filesystem_case_sensitive = request.filesystem_case_sensitive
    if filesystem_case_sensitive ~= nil and type(filesystem_case_sensitive) ~= "boolean" then
      if type(filesystem_case_sensitive) ~= "table" then
        error("native.request.filesystem_case_sensitive must be boolean or a path table", 3)
      end
      for name, value in pairs(filesystem_case_sensitive) do
        if type(name) ~= "string" or type(value) ~= "boolean" then
          error("native.request.filesystem_case_sensitive must be boolean or a path table", 3)
        end
      end
    end
    resolved.native.request = copy(native.request)
  end
  if native.mappings ~= nil then
    if type(native.mappings) ~= "table" then
      error("native.mappings must be a table", 3)
    end
    reject_unknown(native.mappings, {
      next = true,
      previous = true,
      accept = true,
      cancel = true,
    }, "native.mappings")
    for _, name in ipairs({ "next", "previous", "accept", "cancel" }) do
      local mapping = native.mappings[name]
      if mapping ~= nil and mapping ~= false and (type(mapping) ~= "string" or mapping == "") then
        error("native.mappings." .. name .. " must be a non-empty string or false", 3)
      end
      if mapping ~= nil then
        resolved.native.mappings[name] = mapping
      end
    end
  end

  local seen = {}
  for _, name in ipairs({ "next", "previous", "accept", "cancel" }) do
    local mapping = resolved.native.mappings[name]
    if mapping ~= false then
      if seen[mapping] ~= nil then
        error("native mappings must be unique: " .. seen[mapping] .. " and " .. name, 3)
      end
      seen[mapping] = name
    end
  end
end

function M.resolve(options)
  if options ~= nil and type(options) ~= "table" then
    error("setup options must be a table", 2)
  end
  options = options or {}

  reject_unknown(options, {
    limit = true,
    max_limit = true,
    matching_style = true,
    categories = true,
    filesystem = true,
    native = true,
    debug = true,
  }, "setup")

  local resolved = copy(defaults)
  if options.matching_style ~= nil then
    if options.matching_style ~= "extended" and options.matching_style ~= "emacs" then
      error("matching_style must be extended or emacs", 2)
    end
    resolved.matching_style = options.matching_style
  end
  if options.limit ~= nil then
    positive_integer(options.limit, "limit")
    resolved.limit = options.limit
  end
  if options.max_limit ~= nil then
    positive_integer(options.max_limit, "max_limit")
    resolved.max_limit = options.max_limit
  end
  if resolved.limit > resolved.max_limit then
    error("limit must not exceed max_limit", 2)
  end
  resolve_filesystem(options, resolved)
  resolve_native(options, resolved)
  resolve_debug(options, resolved)

  if options.categories ~= nil then
    if type(options.categories) ~= "table" then
      error("categories must be a table", 2)
    end
    for category, category_options in pairs(options.categories) do
      if type(category) ~= "string" or type(category_options) ~= "table" then
        error("category configuration must map strings to tables", 2)
      end
      reject_unknown(category_options, {
        profile = true,
        case_mode = true,
        matching_style = true,
      }, "categories." .. category)
      local profile = category_options.profile
      if profile ~= nil and profile ~= "path" and profile ~= "symbol" and profile ~= "generic" then
        error("invalid profile for category " .. category, 2)
      end
      local case_mode = category_options.case_mode
      if
        case_mode ~= nil
        and case_mode ~= "sensitive"
        and case_mode ~= "insensitive"
        and case_mode ~= "smart"
        and case_mode ~= "filesystem"
      then
        error("invalid case_mode for category " .. category, 2)
      end
      local matching_style = category_options.matching_style
      if matching_style ~= nil and matching_style ~= "extended" and matching_style ~= "emacs" then
        error("invalid matching_style for category " .. category, 2)
      end
      resolved.categories[category] = copy(category_options)
    end
  end

  return resolved
end

function M.profile_for(config, request, candidate)
  local override = config.categories[request.category] or {}
  local request_context = request.context or {}
  local path_separator = path_semantics.platform(request_context.platform) == "windows" and "both" or "/"
  return {
    category = request.category,
    profile = override.profile or boundaries.profile_for(request.category, request.query, candidate, path_separator),
    case_mode = request.case_mode or override.case_mode or boundaries.default_case_mode(request.category),
    matching_style = request.matching_style or override.matching_style or config.matching_style,
    allow_subsequence = request.allow_subsequence == true,
    path_separator = path_separator,
  }
end

function M.copy(value, depth_limit)
  return copy(value, nil, nil, depth_limit)
end

return M
