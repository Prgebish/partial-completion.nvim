local Cache = require("partial_completion.cache")
local boundaries = require("partial_completion.boundaries")
local logger = require("partial_completion.logger")
local matcher = require("partial_completion.matcher")
local path_semantics = require("partial_completion.path")
local types = require("partial_completion.types")

local M = {
  api_version = 1,
  categories = { "path" },
}
local pending_request_count = 0

local function error_result(code, original)
  return {
    status = "error",
    error_code = code,
    original = original,
  }
end

local function runtime_context(context)
  context = context or {}
  local platform = path_semantics.platform(context.platform)
  local raw_cwd = context.cwd or vim.uv.cwd() or vim.fn.getcwd()
  local cwd = path_semantics.normalize_absolute(raw_cwd, platform)
  return {
    cwd = cwd or raw_cwd,
    home = context.home or (platform == "windows" and vim.env.USERPROFILE or vim.env.HOME) or vim.env.HOME,
    env = context.env,
    platform = platform,
  }
end

local function environment_value(context, name)
  if context.env ~= nil then
    return context.env[name]
  end
  return vim.env[name]
end

local function parsed(root_kind, root_text, scan_root, remainder)
  return {
    status = "ok",
    root_kind = root_kind,
    root_text = root_text,
    scan_root = scan_root,
    remainder = remainder,
  }
end

local function parse_environment(input, context)
  local name, root_text, remainder, separator
  name, separator, remainder = string.match(input, "^%${([A-Za-z_][A-Za-z0-9_]*)}([\\/])(.*)$")
  if name ~= nil then
    root_text = "${" .. name .. "}" .. separator
  else
    name = string.match(input, "^%${([A-Za-z_][A-Za-z0-9_]*)}$")
    if name ~= nil then
      root_text = "${" .. name .. "}"
      remainder = ""
    end
  end

  if name == nil then
    name, separator, remainder = string.match(input, "^%$([A-Za-z_][A-Za-z0-9_]*)([\\/])(.*)$")
    if name ~= nil then
      root_text = "$" .. name .. separator
    else
      name = string.match(input, "^%$([A-Za-z_][A-Za-z0-9_]*)$")
      if name ~= nil then
        root_text = "$" .. name
        remainder = ""
      end
    end
  end

  if name == nil then
    return nil
  end
  if separator == "\\" and context.platform ~= "windows" then
    return nil
  end

  local value = environment_value(context, name)
  if type(value) ~= "string" then
    return error_result("undefined_environment_variable", input)
  end
  local resolved = path_semantics.resolve(value, context.cwd, context.platform)
  if resolved == nil then
    return error_result("unsupported_root", input)
  end
  return parsed("environment", root_text, resolved, remainder)
end

local function parse_windows_root(input, context)
  local drive, separator, remainder = string.match(input, "^([A-Za-z]):([\\/])(.*)$")
  if drive ~= nil then
    local root_text = drive .. ":" .. separator
    return parsed("drive", root_text, string.upper(drive) .. ":/", remainder)
  end
  if string.match(input, "^[A-Za-z]:") then
    return error_result("unsupported_root", input)
  end

  local root_text, leading, server, middle, share, trailing
  leading, server, middle, share, trailing, remainder =
    string.match(input, "^([\\/][\\/])([^\\/]+)([\\/])([^\\/]+)([\\/])(.*)$")
  if leading == nil then
    leading, server, middle, share = string.match(input, "^([\\/][\\/])([^\\/]+)([\\/])([^\\/]+)$")
    remainder = ""
  end
  if server ~= nil then
    root_text = leading .. server .. middle .. share .. (trailing or "")
    return parsed("unc", root_text, "//" .. server .. "/" .. share, remainder)
  end
  if string.match(input, "^[\\/][\\/]") then
    return error_result("unsupported_root", input)
  end

  local first = string.sub(input, 1, 1)
  if path_semantics.is_separator(first, "windows") then
    local scan_root = path_semantics.resolve(first, context.cwd, "windows")
    if scan_root == nil then
      return error_result("unsupported_root", input)
    end
    return parsed("absolute", first, scan_root, string.sub(input, 2))
  end
  return nil
end

function M.parse_root(input, context)
  if type(input) ~= "string" then
    error("path input must be a string", 2)
  end
  context = runtime_context(context)

  if context.platform == "posix" and (string.match(input, "^[A-Za-z]:[\\/]") or string.sub(input, 1, 2) == "\\\\") then
    return error_result("unsupported_root", input)
  end
  if context.platform == "windows" then
    local windows_root = parse_windows_root(input, context)
    if windows_root ~= nil then
      return windows_root
    end
  elseif string.sub(input, 1, 1) == "/" then
    return parsed("absolute", "/", "/", string.sub(input, 2))
  end
  if input == "~" then
    if type(context.home) ~= "string" or context.home == "" then
      return error_result("undefined_home_directory", input)
    end
    local home = path_semantics.resolve(context.home, context.cwd, context.platform)
    return home and parsed("home", "~", home, "") or error_result("unsupported_root", input)
  end
  local home_separator = string.match(input, "^~([\\/])")
  if home_separator ~= nil and (context.platform == "windows" or home_separator == "/") then
    if type(context.home) ~= "string" or context.home == "" then
      return error_result("undefined_home_directory", input)
    end
    local home = path_semantics.resolve(context.home, context.cwd, context.platform)
    return home and parsed("home", "~" .. home_separator, home, string.sub(input, 3))
      or error_result("unsupported_root", input)
  end
  if string.sub(input, 1, 1) == "~" then
    return error_result("unsupported_root", input)
  end

  local environment = parse_environment(input, context)
  if environment ~= nil then
    return environment
  end
  local normalized_input = context.platform == "windows" and string.gsub(input, "\\", "/") or input
  if string.sub(normalized_input, 1, 2) == "./" then
    return parsed("cwd", string.sub(input, 1, 2), context.cwd, string.sub(input, 3))
  end
  if input == ".." then
    return parsed("parent", "..", path_semantics.resolve("..", context.cwd, context.platform), "")
  end
  if string.sub(normalized_input, 1, 3) == "../" then
    local offset = 1
    while string.sub(normalized_input, offset, offset + 2) == "../" do
      offset = offset + 3
    end
    local root_text = string.sub(input, 1, offset - 1)
    return parsed(
      "parent",
      root_text,
      path_semantics.resolve(string.sub(normalized_input, 1, offset - 1), context.cwd, context.platform),
      string.sub(input, offset)
    )
  end
  return parsed("relative", "", context.cwd, input)
end

local defaults = {
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
}

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copy(child)
  end
  return result
end

local function merge_options(options)
  local resolved = copy(defaults)
  options = options or {}
  for key, value in pairs(options) do
    if key == "cache" and type(value) == "table" then
      for cache_key, cache_value in pairs(value) do
        resolved.cache[cache_key] = cache_value
      end
    else
      resolved[key] = value
    end
  end
  return resolved
end

local function join_path(parent, name)
  return path_semantics.join(parent, name)
end

local function resolve_link_target(link_path, target, platform)
  local resolved = path_semantics.resolve(target, path_semantics.dirname(link_path, platform), platform)
  return resolved or link_path
end

local function split_components(remainder, preserve_empty, separator_mode)
  if preserve_empty then
    local parsed_components = boundaries.components(remainder, separator_mode)
    local components = {}
    for _, component in ipairs(parsed_components or {}) do
      components[#components + 1] = component.text
    end
    return components
  end
  local components = {}
  local parsed_components = boundaries.components(remainder, separator_mode)
  for _, component in ipairs(parsed_components or {}) do
    if component.text ~= "" then
      components[#components + 1] = component.text
    end
  end
  local trailing = string.sub(remainder, -1)
  if remainder == "" or trailing == "/" or (separator_mode == "both" and trailing == "\\") then
    components[#components + 1] = ""
  end
  return components
end

local function insertion_text(root_text, components, directory, separator, platform)
  local body = table.concat(components, separator)
  local text
  if root_text == "" then
    text = body
  elseif body == "" then
    text = root_text
  elseif path_semantics.is_separator(string.sub(root_text, -1), platform) then
    text = root_text .. body
  else
    text = root_text .. separator .. body
  end
  if directory and not path_semantics.is_separator(string.sub(text, -1), platform) then
    text = text .. separator
  end
  return text
end

local function copy_array(values)
  local result = {}
  for index, value in ipairs(values) do
    result[index] = value
  end
  return result
end

local function copy_set(values)
  local result = {}
  for key, value in pairs(values) do
    result[key] = value
  end
  return result
end

local function append_component(components, name)
  local result = copy_array(components)
  result[#result + 1] = name
  return result
end

local function uv_error(err, fallback_code, fallback_message)
  local message = tostring(err or "")
  if string.find(message, "EACCES", 1, true) or string.find(message, "EPERM", 1, true) then
    return types.error("permission_denied", "permission denied while reading a directory", true)
  end
  if string.find(message, "ENOENT", 1, true) then
    return types.error("path_not_found", "path disappeared during completion", true)
  end
  return types.error(fallback_code or "filesystem_error", fallback_message or "filesystem operation failed", true)
end

local function has_uv_error(err, code)
  return string.find(tostring(err or ""), code, 1, true) ~= nil
end

local function unavailable_link(err)
  return has_uv_error(err, "ENOENT") or has_uv_error(err, "ELOOP")
end

local function hidden_allowed(mode, component, name)
  if string.sub(name, 1, 1) ~= "." then
    return true
  end
  if mode == "always" then
    return true
  end
  if mode == "never" then
    return false
  end
  return string.sub(component, 1, 1) == "."
end

local function toggled_ascii_name(name)
  for index = 1, #name do
    local byte = string.byte(name, index)
    if byte >= 65 and byte <= 90 then
      return string.sub(name, 1, index - 1) .. string.char(byte + 32) .. string.sub(name, index + 1)
    end
    if byte >= 97 and byte <= 122 then
      return string.sub(name, 1, index - 1) .. string.char(byte - 32) .. string.sub(name, index + 1)
    end
  end
  return nil
end

local function entry_size(entries)
  local size = 32
  for _, entry in ipairs(entries) do
    size = size + #entry.name + 16
  end
  return size
end

local function new_instance(options)
  local instance = {
    options = merge_options(options),
    cache = nil,
    case_cache = {},
    io_stats = {
      stat_calls = 0,
      inflight_stats = 0,
      max_concurrent_stats = 0,
    },
  }

  local function reset_cache()
    instance.cache = Cache.new(instance.options.cache)
    instance.case_cache = Cache.new(instance.options.cache)
  end
  reset_cache()

  local provider = {
    api_version = 1,
    categories = { "path" },
  }

  function provider.configure(new_options)
    local resolved = merge_options(new_options)
    if vim.deep_equal(instance.options, resolved) then
      return
    end
    instance.options = resolved
    reset_cache()
  end

  function provider.invalidate_cache(path)
    if path == nil then
      instance.cache:invalidate()
      instance.case_cache:invalidate()
      return
    end
    local platform = path_semantics.platform()
    local key = path_semantics.is_absolute(path, platform) and path_semantics.normalize_absolute(path, platform) or path
    instance.cache:invalidate(key)
    instance.case_cache:invalidate(key)
    local physical = vim.uv.fs_realpath(key)
    if physical ~= nil and physical ~= key then
      physical = path_semantics.normalize_absolute(physical, platform)
      instance.cache:invalidate(physical)
      instance.case_cache:invalidate(physical)
    end
  end

  function provider.cache_stats()
    local stats = instance.cache:stats()
    local case_stats = instance.case_cache:stats()
    stats.case_entries = case_stats.entries
    stats.case_bytes = case_stats.bytes
    stats.case_evictions = case_stats.evictions
    stats.case_expirations = case_stats.expirations
    stats.case_hits = case_stats.hits
    stats.case_misses = case_stats.misses
    stats.case_invalidations = case_stats.invalidations
    stats.stat_calls = instance.io_stats.stat_calls
    stats.max_concurrent_stats = instance.io_stats.max_concurrent_stats
    return stats
  end

  function provider.complete(request, emit, done)
    local options_snapshot = instance.options
    local directory_cache = instance.cache
    local case_cache = instance.case_cache
    local active = true
    local terminal = false
    local active_requests = {}
    local active_timers = {}
    local state = {
      case_mode = request.case_mode ~= nil and request.case_mode ~= "filesystem" and request.case_mode or nil,
      emitted = 0,
      incomplete = false,
      scan_work = 0,
      source_order = 0,
      first_error = nil,
      chunk = {},
      incomplete_sent = false,
    }
    local context = request.context or {}
    local platform = path_semantics.platform(context.platform)
    local separator_mode = platform == "windows" and "both" or "/"
    local insertion_separator = path_semantics.separator(request.query, platform)
    local emacs_style = request.matching_style == "emacs"
    local root_context = {
      cwd = request.cwd or context.cwd,
      home = context.home,
      env = context.env,
      platform = platform,
    }
    local root = M.parse_root(request.query, root_context)
    local result_limit = math.min(request.limit or options_snapshot.max_results, options_snapshot.max_results)
    if logger.enabled() then
      logger.debug("filesystem_started", {
        request_id = request.request_id,
        query = request.query,
        cwd = root_context.cwd,
        root = root.scan_root,
        root_kind = root.root_kind,
        platform = platform,
      })
    end

    local function cancel_requests()
      for handle in pairs(active_requests) do
        pcall(vim.uv.cancel, handle)
      end
      for timer in pairs(active_timers) do
        active_timers[timer] = nil
        pcall(timer.stop, timer)
        if not timer:is_closing() then
          timer:close()
        end
      end
    end

    local function track_request(handle)
      if handle ~= nil and active_requests[handle] == nil then
        active_requests[handle] = true
        pending_request_count = pending_request_count + 1
      end
    end

    local function untrack_request(handle)
      if handle ~= nil and active_requests[handle] ~= nil then
        active_requests[handle] = nil
        pending_request_count = math.max(0, pending_request_count - 1)
      end
    end

    local function flush()
      if not active or #state.chunk == 0 then
        return
      end
      local chunk = state.chunk
      state.chunk = {}
      emit(chunk, {
        is_incomplete = state.incomplete,
        resolved_case_mode = state.case_mode,
      })
      if state.incomplete then
        state.incomplete_sent = true
      end
    end

    local function finish(err)
      if not active or terminal then
        return
      end
      flush()
      if state.incomplete and not state.incomplete_sent then
        emit({}, { is_incomplete = true, resolved_case_mode = state.case_mode })
      end
      terminal = true
      cancel_requests()
      if err == nil and state.emitted == 0 then
        err = state.first_error
      end
      if logger.enabled() then
        logger.debug("filesystem_finished", {
          request_id = request.request_id,
          emitted = state.emitted,
          scan_work = state.scan_work,
          incomplete = state.incomplete,
          error_code = err and err.code or nil,
        })
      end
      done(err)
    end

    local function remember_error(err)
      if state.first_error == nil then
        state.first_error = err
      end
      state.incomplete = true
    end

    local function add_item(item)
      if not active or terminal then
        return false
      end
      if state.emitted >= result_limit then
        state.incomplete = true
        return false
      end
      state.source_order = state.source_order + 1
      item.source_order = state.source_order
      state.chunk[#state.chunk + 1] = item
      state.emitted = state.emitted + 1
      if #state.chunk >= options_snapshot.emit_chunk_size then
        flush()
      end
      return state.emitted < result_limit
    end

    local function schedule(callback)
      vim.schedule(function()
        if active and not terminal then
          callback()
        end
      end)
    end

    local function yield_event_loop(callback)
      local timer = vim.uv.new_timer()
      active_timers[timer] = true
      timer:start(0, 0, function()
        active_timers[timer] = nil
        timer:stop()
        timer:close()
        schedule(callback)
      end)
    end

    local function fs_request(method, path, callback)
      local handle
      local immediate_error
      local is_stat = method == vim.uv.fs_stat
      if is_stat then
        instance.io_stats.stat_calls = instance.io_stats.stat_calls + 1
        instance.io_stats.inflight_stats = instance.io_stats.inflight_stats + 1
        instance.io_stats.max_concurrent_stats =
          math.max(instance.io_stats.max_concurrent_stats, instance.io_stats.inflight_stats)
      end
      handle, immediate_error = method(path, function(err, value)
        if is_stat then
          instance.io_stats.inflight_stats = math.max(0, instance.io_stats.inflight_stats - 1)
        end
        untrack_request(handle)
        schedule(function()
          callback(err, value)
        end)
      end)
      if handle ~= nil then
        track_request(handle)
      else
        if is_stat then
          instance.io_stats.inflight_stats = math.max(0, instance.io_stats.inflight_stats - 1)
        end
        schedule(function()
          callback(immediate_error or "EIO", nil)
        end)
      end
    end

    local function scan_directory(path, identity, callback)
      local cache_key = identity or path
      local cached = directory_cache:get(cache_key)
      if cached ~= nil then
        schedule(function()
          callback(nil, cached, true, false)
        end)
        return
      end
      if state.scan_work >= options_snapshot.max_entries_scanned then
        state.incomplete = true
        schedule(function()
          callback(nil, {}, false, true)
        end)
        return
      end

      local handle
      local immediate_error
      handle, immediate_error = vim.uv.fs_scandir(path, function(err, scan)
        untrack_request(handle)
        schedule(function()
          if not active or terminal then
            return
          end
          if err ~= nil then
            callback(err, nil, false, false)
            return
          end

          local entries = {}
          local exhausted = false
          local truncated = false
          local function drain()
            if not active or terminal then
              return
            end
            local processed = 0
            while processed < options_snapshot.scan_chunk_size do
              if state.scan_work >= options_snapshot.max_entries_scanned then
                local extra_name = vim.uv.fs_scandir_next(scan)
                truncated = extra_name ~= nil
                exhausted = extra_name == nil
                break
              end
              local name, entry_type = vim.uv.fs_scandir_next(scan)
              if name == nil then
                exhausted = true
                break
              end
              state.scan_work = state.scan_work + 1
              processed = processed + 1
              entries[#entries + 1] = { name = name, type = entry_type }
            end

            if exhausted or truncated then
              table.sort(entries, function(left, right)
                if left.name ~= right.name then
                  return left.name < right.name
                end
                return tostring(left.type) < tostring(right.type)
              end)
              if exhausted and not truncated then
                directory_cache:set(cache_key, entries, entry_size(entries))
              else
                state.incomplete = true
              end
              callback(nil, entries, false, truncated)
            else
              yield_event_loop(drain)
            end
          end
          drain()
        end)
      end)
      if handle ~= nil then
        track_request(handle)
      else
        schedule(function()
          callback(immediate_error or "EIO", nil, false, false)
        end)
      end
    end

    local function stream_directory(path, identity, on_chunk, callback)
      local cache_key = identity or path
      local cached = directory_cache:get(cache_key)
      if cached ~= nil then
        local offset = 1
        local function deliver_cached()
          if offset > #cached then
            callback(nil, false)
            return
          end
          local chunk = {}
          local last = math.min(#cached, offset + options_snapshot.scan_chunk_size - 1)
          for index = offset, last do
            chunk[#chunk + 1] = cached[index]
          end
          offset = last + 1
          on_chunk(chunk, function()
            yield_event_loop(deliver_cached)
          end, true)
        end
        schedule(deliver_cached)
        return
      end
      if state.scan_work >= options_snapshot.max_entries_scanned then
        state.incomplete = true
        schedule(function()
          callback(nil, true)
        end)
        return
      end

      local handle
      local immediate_error
      handle, immediate_error = vim.uv.fs_scandir(path, function(err, scan)
        untrack_request(handle)
        schedule(function()
          if not active or terminal then
            return
          end
          if err ~= nil then
            callback(err, false)
            return
          end

          local cache_entries = options_snapshot.cache.ttl_ms > 0 and {} or nil
          local cache_size = 32
          local exhausted = false
          local truncated = false
          local function drain()
            if not active or terminal then
              return
            end
            local chunk = {}
            while #chunk < options_snapshot.scan_chunk_size do
              if state.scan_work >= options_snapshot.max_entries_scanned then
                local extra_name = vim.uv.fs_scandir_next(scan)
                truncated = extra_name ~= nil
                exhausted = extra_name == nil
                break
              end
              local name, entry_type = vim.uv.fs_scandir_next(scan)
              if name == nil then
                exhausted = true
                break
              end
              state.scan_work = state.scan_work + 1
              local entry = { name = name, type = entry_type }
              chunk[#chunk + 1] = entry
              if cache_entries ~= nil then
                local next_size = cache_size + #name + 16
                if next_size <= options_snapshot.cache.max_bytes then
                  cache_entries[#cache_entries + 1] = entry
                  cache_size = next_size
                else
                  cache_entries = nil
                end
              end
            end

            local function continue_scan()
              if exhausted or truncated then
                if exhausted and not truncated and cache_entries ~= nil then
                  table.sort(cache_entries, function(left, right)
                    if left.name ~= right.name then
                      return left.name < right.name
                    end
                    return tostring(left.type) < tostring(right.type)
                  end)
                  directory_cache:set(cache_key, cache_entries, cache_size)
                else
                  state.incomplete = state.incomplete or truncated
                end
                callback(nil, truncated)
              else
                yield_event_loop(drain)
              end
            end

            if #chunk > 0 then
              on_chunk(chunk, continue_scan, false)
            else
              continue_scan()
            end
          end
          drain()
        end)
      end)
      if handle ~= nil then
        track_request(handle)
      else
        schedule(function()
          callback(immediate_error or "EIO", false)
        end)
      end
    end

    local function fallback_case_sensitive()
      if type(context.filesystem_case_sensitive) == "boolean" then
        return context.filesystem_case_sensitive
      end
      if type(options_snapshot.case_sensitive) == "boolean" then
        return options_snapshot.case_sensitive
      end
      return not vim.o.fileignorecase
    end

    local function directory_case_sensitive(path)
      if type(context.filesystem_case_sensitive) == "table" then
        local sensitive = context.filesystem_case_sensitive[path]
        if type(sensitive) == "boolean" then
          return sensitive
        end
      end
      return nil
    end

    local function known_case_mode(path)
      if state.case_mode ~= nil then
        return state.case_mode
      end
      local directory_sensitive = directory_case_sensitive(path)
      if directory_sensitive ~= nil then
        return directory_sensitive and "sensitive" or "insensitive"
      end
      if type(options_snapshot.case_sensitive) == "boolean" or type(context.filesystem_case_sensitive) == "boolean" then
        return fallback_case_sensitive() and "sensitive" or "insensitive"
      end
      local cached = case_cache:get(path)
      if cached ~= nil then
        return cached.sensitive and "sensitive" or "insensitive"
      end
      return nil
    end

    local function detect_case_mode(path, entries, callback)
      local known = known_case_mode(path)
      if known ~= nil then
        callback(known)
        return
      end

      local names = {}
      for _, entry in ipairs(entries) do
        names[entry.name] = true
      end
      local probe
      for _, entry in ipairs(entries) do
        local toggled = toggled_ascii_name(entry.name)
        if toggled ~= nil and not names[toggled] then
          probe = toggled
          break
        end
      end
      if probe == nil then
        local sensitive = fallback_case_sensitive()
        case_cache:set(path, { sensitive = sensitive }, #path + 16)
        callback(sensitive and "sensitive" or "insensitive")
        return
      end

      fs_request(vim.uv.fs_lstat, join_path(path, probe), function(err)
        local sensitive
        if err == nil then
          sensitive = false
        elseif string.find(tostring(err), "ENOENT", 1, true) then
          sensitive = true
        else
          sensitive = fallback_case_sensitive()
        end
        case_cache:set(path, { sensitive = sensitive }, #path + 16)
        callback(sensitive and "sensitive" or "insensitive")
      end)
    end

    local function rank_entries(component, proposals)
      local candidates = {}
      for index, proposal in ipairs(proposals) do
        local portable = platform ~= "windows" or path_semantics.valid_windows_entry(proposal.entry.name)
        if
          proposal.navigation or (portable and hidden_allowed(options_snapshot.hidden, component, proposal.entry.name))
        then
          candidates[#candidates + 1] = {
            id = tostring(index) .. ":" .. proposal.entry.name,
            label = proposal.entry.name,
            insert_text = proposal.entry.name,
            source_order = index,
            data = proposal,
            _case_mode = proposal.case_mode,
          }
        end
      end
      return matcher.rank(component, candidates, {
        category = "path",
        profile = "path",
        case_mode = state.case_mode,
        matching_style = request.matching_style,
        allow_subsequence = request.allow_subsequence == true,
        path_separator = separator_mode,
      })
    end

    local function resolve_realpath(path, callback)
      fs_request(vim.uv.fs_realpath, path, function(err, physical)
        if err ~= nil then
          callback(err, nil)
        else
          callback(nil, path_semantics.normalize_absolute(physical, platform))
        end
      end)
    end

    local function resolve_directory(proposal, callback)
      local path = join_path(proposal.branch.scan_path, proposal.entry.name)
      local function with_realpath(scan_path)
        resolve_realpath(path, function(err, physical)
          if err ~= nil then
            callback(err, nil)
            return
          end
          if not proposal.navigation and proposal.branch.visited[physical] then
            callback(nil, nil)
            return
          end
          local visited = proposal.navigation and {} or copy_set(proposal.branch.visited)
          visited[physical] = true
          callback(nil, {
            scan_path = scan_path,
            identity = physical,
            display_components = append_component(proposal.branch.display_components, proposal.entry.name),
            visited = visited,
          })
        end)
      end

      local function validate_cached()
        fs_request(vim.uv.fs_stat, path, function(err, stat)
          if err ~= nil then
            directory_cache:invalidate(proposal.cache_key)
            case_cache:invalidate(proposal.cache_key)
            callback(err, nil)
            return
          end
          if stat == nil or stat.type ~= proposal.entry.type then
            directory_cache:invalidate(proposal.cache_key)
            case_cache:invalidate(proposal.cache_key)
          end
          if stat ~= nil and stat.type == "directory" then
            with_realpath(path)
          else
            callback(nil, nil)
          end
        end)
      end

      if proposal.navigation then
        with_realpath(path)
      elseif proposal.cached then
        validate_cached()
      elseif proposal.entry.type == "directory" then
        with_realpath(path)
      elseif proposal.entry.type == "link" or proposal.entry.type == nil then
        fs_request(vim.uv.fs_stat, path, function(err, stat)
          if err ~= nil or stat == nil or stat.type ~= "directory" then
            callback(err, nil)
            return
          end
          if proposal.entry.type == "link" then
            fs_request(vim.uv.fs_readlink, path, function(link_err, target)
              if link_err ~= nil then
                callback(link_err, nil)
                return
              end
              with_realpath(resolve_link_target(path, target, platform))
            end)
          else
            with_realpath(path)
          end
        end)
      else
        callback(nil, nil)
      end
    end

    local function make_item(branch, entry, stat, physical)
      local kind = (stat and stat.type) or entry.type or "file"
      local broken = false
      if entry.type == "link" then
        if stat == nil then
          kind = "symlink"
          broken = true
        else
          kind = stat.type == "directory" and "directory" or "file"
        end
      end
      local components = append_component(branch.display_components, entry.name)
      local text = insertion_text(root.root_text, components, kind == "directory", insertion_separator, platform)
      return {
        id = "filesystem:" .. text,
        label = text,
        insert_text = text,
        kind = kind,
        data = {
          path = physical or join_path(branch.scan_path, entry.name),
          exists = not broken,
          broken = broken,
        },
        _case_mode = branch.case_mode,
      }
    end

    local function resolve_final(proposal, callback)
      local path = join_path(proposal.branch.scan_path, proposal.entry.name)
      fs_request(vim.uv.fs_stat, path, function(err, stat)
        if err ~= nil then
          if unavailable_link(err) and proposal.entry.type == "link" then
            callback(nil, make_item(proposal.branch, proposal.entry, nil, path))
          else
            callback(err, nil)
          end
          return
        end
        if
          proposal.cached
          and proposal.entry.type ~= nil
          and proposal.entry.type ~= "link"
          and stat ~= nil
          and stat.type ~= proposal.entry.type
        then
          proposal.cache_stale = true
        end
        if proposal.entry.type ~= "link" then
          local physical = proposal.navigation and path_semantics.normalize_absolute(path, platform) or path
          callback(nil, make_item(proposal.branch, proposal.entry, stat, physical))
          return
        end
        fs_request(vim.uv.fs_readlink, path, function(link_err, target)
          local physical = link_err == nil and resolve_link_target(path, target, platform) or path
          callback(nil, make_item(proposal.branch, proposal.entry, stat, physical))
        end)
      end)
    end

    local components = split_components(root.remainder, emacs_style, separator_mode)
    local function complete_final(branches, component)
      local retry_incomplete_baseline = state.incomplete
      local retry_error_baseline = state.first_error
      local branch_index = 1
      local proposal_order = 0
      local preliminary_emitted = false
      local top_items = {}
      local retry_count = 0
      local validation_reserve = math.min(result_limit, 16)
      local retained_limit = result_limit + validation_reserve
      local uncertain_limit = retained_limit
      local fallback_limit = math.max(2, math.min(options_snapshot.branch_limit, 16))
      local validation_concurrency = 8
      local final_profile = {
        category = "path",
        profile = "path",
        case_mode = state.case_mode,
        matching_style = request.matching_style,
        allow_subsequence = request.allow_subsequence == true,
        path_separator = separator_mode,
      }

      local function emit_snapshot(items)
        if not active or terminal then
          return
        end
        state.chunk = {}
        state.emitted = #items
        emit(items, {
          is_incomplete = state.incomplete,
          replace = true,
          resolved_case_mode = state.case_mode,
        })
        if state.incomplete then
          state.incomplete_sent = true
        end
      end

      local function publish_top(callback, defer_stale_snapshot)
        if #top_items == 0 then
          emit_snapshot({})
          callback({})
          return
        end
        local actual_by_index = {}
        local stale_cache_keys = {}
        local expected_ids = {}
        local expected_count = 0
        for _, candidate in ipairs(top_items) do
          if not context.only_directories or candidate._directory_confidence == "known" then
            if not expected_ids[candidate.id] then
              expected_ids[candidate.id] = true
              expected_count = expected_count + 1
            end
          end
        end
        local next_index = 1
        local inflight = 0
        local completed = 0

        local function finalize_validation()
          local actual_items = {}
          local seen_items = {}
          for index = 1, #top_items do
            local actual = actual_by_index[index]
            if actual ~= nil and not seen_items[actual.id] then
              seen_items[actual.id] = true
              actual_items[#actual_items + 1] = actual
            end
          end
          for cache_key in pairs(stale_cache_keys) do
            directory_cache:invalidate(cache_key)
            case_cache:invalidate(cache_key)
          end
          local required_count = math.min(expected_count, result_limit)
          if defer_stale_snapshot and next(stale_cache_keys) ~= nil and #actual_items < required_count then
            callback(stale_cache_keys)
            return
          end
          local ranked = matcher.rank(request.query, actual_items, final_profile)
          local snapshot = {}
          for index = 1, math.min(#ranked, result_limit) do
            snapshot[index] = ranked[index]
          end
          emit_snapshot(snapshot)
          callback({})
        end

        local pump
        local function validate(candidate_index)
          local candidate = top_items[candidate_index]
          local proposal = candidate._proposal
          resolve_final(proposal, function(err, item)
            if err ~= nil then
              if unavailable_link(err) then
                if proposal.cached then
                  stale_cache_keys[proposal.cache_key] = true
                end
              else
                remember_error(uv_error(err))
              end
            else
              if proposal.cache_stale then
                stale_cache_keys[proposal.cache_key] = true
              end
            end
            if err == nil and item ~= nil and (not context.only_directories or item.kind == "directory") then
              item.source_order = proposal.source_order
              actual_by_index[candidate_index] = item
            end
            inflight = inflight - 1
            completed = completed + 1
            pump()
          end)
        end

        pump = function()
          if completed == #top_items then
            finalize_validation()
            return
          end
          while inflight < validation_concurrency and next_index <= #top_items do
            local candidate_index = next_index
            next_index = next_index + 1
            inflight = inflight + 1
            validate(candidate_index)
          end
        end
        pump()
      end

      local function merge_candidates(candidates)
        for _, candidate in ipairs(candidates) do
          top_items[#top_items + 1] = candidate
        end
        local ranked = matcher.rank(request.query, top_items, final_profile)
        local groups = {}
        local group_order = {}
        for _, candidate in ipairs(ranked) do
          local group = groups[candidate.id]
          if group == nil then
            group = { known_directory = false }
            groups[candidate.id] = group
            group_order[#group_order + 1] = candidate.id
          end
          if candidate._directory_confidence == "known" then
            group.known_directory = true
          end
        end

        local selected_ids = {}
        local selected_known = 0
        local selected_uncertain = 0
        if context.only_directories then
          for _, id in ipairs(group_order) do
            local group = groups[id]
            if group.known_directory then
              if selected_known < retained_limit then
                selected_ids[id] = true
                selected_known = selected_known + 1
              else
                state.incomplete = true
              end
            elseif selected_uncertain < uncertain_limit then
              selected_ids[id] = true
              selected_uncertain = selected_uncertain + 1
            else
              state.incomplete = true
            end
          end
          if selected_known > result_limit then
            state.incomplete = true
          end
        else
          for index, id in ipairs(group_order) do
            if index <= retained_limit then
              selected_ids[id] = true
            end
          end
          if #group_order > result_limit then
            state.incomplete = true
          end
        end

        top_items = {}
        local retained_by_id = {}
        for _, candidate in ipairs(ranked) do
          if selected_ids[candidate.id] then
            local retained = retained_by_id[candidate.id] or 0
            if retained < fallback_limit then
              retained_by_id[candidate.id] = retained + 1
              top_items[#top_items + 1] = candidate
            else
              state.incomplete = true
            end
          end
        end
      end

      local function candidate_for(proposal, stat, physical)
        local item = make_item(proposal.branch, proposal.entry, stat, physical)
        item.source_order = proposal.source_order
        item._proposal = proposal
        item._directory_confidence = proposal.entry.type == "directory" and "known" or "uncertain"
        return item
      end

      local function prepare_chunk(branch, entries, cached, callback)
        local candidates = {}
        local component_profile = {
          category = "path",
          profile = "path",
          case_mode = branch.case_mode,
          matching_style = request.matching_style,
          allow_subsequence = request.allow_subsequence == true,
          path_separator = separator_mode,
        }
        local literal_sensitive_prefix = branch.case_mode == "sensitive"
          and request.matching_style ~= "emacs"
          and request.allow_subsequence ~= true
        local function matches_component(name)
          if literal_sensitive_prefix then
            return string.sub(name, 1, #component) == component
          end
          return matcher.match(component, name, component_profile) ~= nil
        end
        for _, entry in ipairs(entries) do
          proposal_order = proposal_order + 1
          local portable = platform ~= "windows" or path_semantics.valid_windows_entry(entry.name)
          local excluded = not portable or not hidden_allowed(options_snapshot.hidden, component, entry.name)
          if not excluded and context.only_directories and not matches_component(entry.name) then
            excluded = true
          end
          if
            not excluded
            and context.only_directories
            and not cached
            and entry.type ~= "directory"
            and entry.type ~= "link"
            and entry.type ~= nil
          then
            excluded = true
          end
          if not excluded then
            local proposal = {
              branch = branch,
              entry = entry,
              source_order = proposal_order,
              case_mode = branch.case_mode,
              cached = cached == true,
              cache_key = branch.identity or branch.scan_path,
            }
            local physical = join_path(branch.scan_path, entry.name)
            candidates[#candidates + 1] = candidate_for(proposal, { type = entry.type }, physical)
          end
        end
        callback(candidates)
      end

      local function process_chunk(branch, entries, continue_scan, cached)
        prepare_chunk(branch, entries, cached, function(candidates)
          merge_candidates(candidates)
          if not preliminary_emitted and #top_items > 0 then
            preliminary_emitted = true
            publish_top(continue_scan)
          else
            continue_scan()
          end
        end)
      end

      local function deliver_buffered(branch, entries, cached, offset, callback)
        if offset > #entries then
          callback()
          return
        end
        local chunk = {}
        local last = math.min(#entries, offset + options_snapshot.scan_chunk_size - 1)
        for index = offset, last do
          chunk[#chunk + 1] = entries[index]
        end
        process_chunk(branch, chunk, function()
          yield_event_loop(function()
            deliver_buffered(branch, entries, cached, last + 1, callback)
          end)
        end, cached)
      end

      local function scan_next_branch()
        if not active or terminal then
          return
        end
        local branch = branches[branch_index]
        if branch == nil then
          publish_top(function(stale_cache_keys)
            if next(stale_cache_keys) ~= nil and retry_count < 1 then
              retry_count = retry_count + 1
              for cache_key in pairs(stale_cache_keys) do
                directory_cache:invalidate(cache_key)
                case_cache:invalidate(cache_key)
              end
              state.incomplete = retry_incomplete_baseline
              state.incomplete_sent = false
              state.first_error = retry_error_baseline
              branch_index = 1
              proposal_order = 0
              preliminary_emitted = false
              top_items = {}
              scan_next_branch()
            else
              finish(nil)
            end
          end, true)
          return
        end
        branch_index = branch_index + 1

        local identity = branch.identity or branch.scan_path
        local case_mode = known_case_mode(identity)
        if case_mode == nil then
          scan_directory(branch.scan_path, branch.identity, function(err, entries, cached)
            if err ~= nil then
              remember_error(uv_error(err))
              scan_next_branch()
              return
            end
            detect_case_mode(identity, entries, function(detected_case_mode)
              branch.case_mode = detected_case_mode
              deliver_buffered(branch, entries, cached, 1, scan_next_branch)
            end)
          end)
          return
        end

        branch.case_mode = case_mode
        stream_directory(branch.scan_path, branch.identity, function(entries, continue_scan, cached)
          process_chunk(branch, entries, continue_scan, cached)
        end, function(err)
          if err ~= nil then
            remember_error(uv_error(err))
          end
          scan_next_branch()
        end)
      end
      scan_next_branch()
    end

    local function traverse_level(branches, component_index)
      if not active or terminal then
        return
      end
      if component_index >= #components then
        complete_final(branches, components[component_index] or "")
        return
      end

      local component = components[component_index]
      local proposals = {}
      local branch_index = 1
      local proposal_order = 0
      local function resolve_ranked(ranked, ranked_index, next_branches)
        if ranked_index > #ranked or #next_branches >= options_snapshot.branch_limit then
          if ranked_index <= #ranked then
            state.incomplete = true
          end
          if #next_branches == 0 then
            finish(nil)
          else
            traverse_level(next_branches, component_index + 1)
          end
          return
        end
        local proposal = ranked[ranked_index].data
        resolve_directory(proposal, function(err, branch)
          if err ~= nil and not unavailable_link(err) then
            remember_error(uv_error(err))
          end
          if branch ~= nil then
            next_branches[#next_branches + 1] = branch
          end
          resolve_ranked(ranked, ranked_index + 1, next_branches)
        end)
      end

      local function scan_next()
        local branch = branches[branch_index]
        if branch == nil or state.scan_work >= options_snapshot.max_entries_scanned then
          if branch ~= nil then
            state.incomplete = true
          end
          resolve_ranked(rank_entries(component, proposals), 1, {})
          return
        end
        branch_index = branch_index + 1
        scan_directory(branch.scan_path, branch.identity, function(err, entries, cached)
          if err ~= nil then
            remember_error(uv_error(err))
            scan_next()
            return
          end
          local function collect(case_mode)
            if emacs_style and (component == "." or component == "..") then
              proposal_order = proposal_order + 1
              proposals[#proposals + 1] = {
                branch = branch,
                entry = { name = component, type = "directory" },
                navigation = true,
                source_order = proposal_order,
                case_mode = case_mode,
                cached = cached == true,
                cache_key = branch.identity or branch.scan_path,
              }
            else
              for _, entry in ipairs(entries) do
                proposal_order = proposal_order + 1
                proposals[#proposals + 1] = {
                  branch = branch,
                  entry = entry,
                  source_order = proposal_order,
                  case_mode = case_mode,
                  cached = cached == true,
                  cache_key = branch.identity or branch.scan_path,
                }
              end
            end
            scan_next()
          end
          detect_case_mode(branch.identity or branch.scan_path, entries, function(case_mode)
            collect(case_mode)
          end)
        end)
      end
      scan_next()
    end

    if root.status == "error" then
      schedule(function()
        finish(types.error(root.error_code, "unable to resolve path root", false))
      end)
    else
      local scan_roots = { root.scan_root }
      if root.root_kind == "relative" and type(context.search_roots) == "table" then
        scan_roots = {}
        local seen_roots = {}
        for _, search_root in ipairs(context.search_roots) do
          if type(search_root) == "string" and search_root ~= "" then
            local resolved = path_semantics.resolve(search_root, root_context.cwd or root.scan_root, platform)
            if resolved ~= nil and not seen_roots[resolved] then
              seen_roots[resolved] = true
              scan_roots[#scan_roots + 1] = resolved
            end
          end
        end
      end

      local initial_branches = {}
      local root_index = 1
      local function resolve_next_root()
        local scan_root = scan_roots[root_index]
        if scan_root == nil then
          if #initial_branches == 0 then
            finish(nil)
          else
            traverse_level(initial_branches, 1)
          end
          return
        end
        root_index = root_index + 1
        resolve_realpath(scan_root, function(err, physical_root)
          if err ~= nil then
            remember_error(uv_error(err, "path_not_found", "path root does not exist"))
          else
            initial_branches[#initial_branches + 1] = {
              scan_path = scan_root,
              identity = physical_root,
              display_components = {},
              visited = { [physical_root] = true },
            }
          end
          resolve_next_root()
        end)
      end

      if root.root_kind == "parent" and root.remainder == "" then
        schedule(function()
          finish(nil)
        end)
      elseif
        root.remainder == ""
        and root.root_text ~= ""
        and not path_semantics.is_separator(string.sub(root.root_text, -1), platform)
      then
        fs_request(vim.uv.fs_stat, root.scan_root, function(err, stat)
          if err ~= nil then
            remember_error(uv_error(err, "path_not_found", "path root does not exist"))
            finish(nil)
            return
          end
          local directory = stat ~= nil and stat.type == "directory"
          if context.only_directories and not directory then
            finish(nil)
            return
          end
          local text = insertion_text(root.root_text, {}, directory, insertion_separator, platform)
          add_item({
            id = "filesystem:" .. text,
            label = text,
            insert_text = text,
            kind = directory and "directory" or "file",
            data = { path = root.scan_root, exists = true },
          })
          finish(nil)
        end)
      else
        resolve_next_root()
      end
    end

    return {
      cancel = function()
        if not active then
          return
        end
        active = false
        if logger.enabled() then
          logger.debug("filesystem_cancelled", {
            request_id = request.request_id,
            emitted = state.emitted,
            scan_work = state.scan_work,
          })
        end
        cancel_requests()
      end,
    }
  end

  return provider
end

M.new = new_instance
M.is_windows_reserved_name = path_semantics.is_windows_reserved_name
M.valid_windows_entry = path_semantics.valid_windows_entry
M.pending_request_count = function()
  return pending_request_count
end

local default_provider = new_instance()
M.complete = default_provider.complete
M.configure = default_provider.configure
M.invalidate_cache = default_provider.invalidate_cache
M.cache_stats = default_provider.cache_stats

return M
