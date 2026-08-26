local cmdline = require("partial_completion.cmdline")
local filesystem = require("partial_completion.providers.filesystem")
local path_semantics = require("partial_completion.path")
local types = require("partial_completion.types")

local M = {
  api_version = 1,
  categories = {
    "path",
    "command",
    "option",
    "buffer",
    "help",
    "function",
    "variable",
    "mapping",
    "generic",
  },
}

local direct_type_by_category = {
  command = "command",
  option = "option",
  buffer = "buffer",
  help = "help",
  ["function"] = "function",
  variable = "var",
  mapping = "mapping",
}

local function base_type(completion_type)
  return string.match(completion_type or "", "^([^,]+)") or ""
end

local function is_custom(completion_type)
  local kind = base_type(completion_type)
  return kind == "custom" or kind == "customlist"
end

local function search_roots(completion_type, cwd, platform)
  local option_name
  if completion_type == "file_in_path" then
    option_name = "path"
  elseif completion_type == "dir_in_path" then
    option_name = "cdpath"
  else
    return nil
  end

  local ok, values = pcall(function()
    return vim.opt[option_name]:get()
  end)
  if not ok or type(values) ~= "table" then
    return { cwd }
  end

  local roots = {}
  local seen = {}
  for _, value in ipairs(values) do
    if
      type(value) == "string"
      and not string.find(value, "*", 1, true)
      and not string.find(value, "?", 1, true)
      and not string.find(value, "[", 1, true)
      and not string.find(value, ";", 1, true)
    then
      local root
      if value == "" or value == "." then
        root = cwd
      else
        root = path_semantics.resolve(value, cwd, platform)
      end
      if root ~= nil and not seen[root] then
        seen[root] = true
        roots[#roots + 1] = root
      end
    end
  end
  return roots
end

local function snapshot_from_request(request)
  local context = request.context or {}
  if type(context.cmdline) == "table" then
    return context.cmdline
  end
  if request.source_text ~= nil then
    return cmdline.analyze(request.source_text, request.cursor_byte, {
      live = false,
      completion_type = context.completion_type,
      completion_pattern = context.completion_pattern,
      cmdtype = context.cmdtype or ":",
      cmdlevel = context.cmdlevel,
      generation = context.controller_generation,
    })
  end
  local completion_type = context.completion_type or direct_type_by_category[request.category] or ""
  return {
    status = completion_type ~= "" and "ok" or "unsupported",
    source_text = request.query,
    cursor_byte = #request.query,
    prefix = request.query,
    completion_base = "",
    completion_pattern = request.query,
    completion_type = completion_type,
    category = request.category,
    query = request.query,
    raw_query = request.query,
    replacement = request.replacement,
    cmdtype = ":",
  }
end

local function path_complete(request, snapshot, emit, done)
  local context = request.context or {}
  local path_context = {}
  for key, value in pairs(context) do
    if key ~= "cmdline" then
      path_context[key] = value
    end
  end
  local completion_type = base_type(snapshot.completion_type)
  local platform = path_semantics.platform(path_context.platform)
  local cwd = request.cwd or vim.uv.cwd() or vim.fn.getcwd()
  path_context.only_directories = completion_type == "dir" or completion_type == "dir_in_path"
  path_context.platform = platform
  path_context.search_roots = path_context.search_roots or search_roots(completion_type, cwd, platform)
  local encode_context = {}
  for key, value in pairs(snapshot) do
    encode_context[key] = value
  end
  encode_context.platform = platform

  return filesystem.complete({
    api_version = 1,
    request_id = request.request_id,
    generation = request.generation,
    category = "path",
    query = snapshot.query,
    cwd = cwd,
    case_mode = request.case_mode,
    matching_style = request.matching_style,
    allow_subsequence = request.allow_subsequence == true,
    limit = request.limit,
    context = path_context,
  }, function(items, metadata)
    local encoded = {}
    for index, item in ipairs(items) do
      local normalized = {}
      for key, value in pairs(item) do
        normalized[key] = value
      end
      normalized.data = normalized.data or {}
      normalized.data.logical_insert_text = item.insert_text
      normalized.insert_text = cmdline.encode(item.insert_text, encode_context)
      encoded[index] = normalized
    end
    emit(encoded, metadata)
  end, done)
end

local function fixed_candidates(snapshot)
  if is_custom(snapshot.completion_type) or snapshot.completion_type == "" then
    local ok, candidates = pcall(vim.fn.getcompletion, snapshot.prefix, "cmdline", false)
    if not ok then
      return nil, types.error("neovim_completion_error", "Neovim command-line completion failed", false)
    end
    return candidates, nil
  end

  local candidates = {}
  local seen = {}
  local function append(values)
    for _, candidate in ipairs(values) do
      if type(candidate) == "string" and not seen[candidate] then
        seen[candidate] = true
        candidates[#candidates + 1] = candidate
      end
    end
  end

  local direct_ok, direct = pcall(vim.fn.getcompletion, "", base_type(snapshot.completion_type), false)
  if direct_ok then
    append(direct)
  end
  local contextual_ok, contextual = pcall(vim.fn.getcompletion, snapshot.prefix, "cmdline", false)
  if contextual_ok then
    append(contextual)
  end
  if not direct_ok and not contextual_ok then
    return nil, types.error("neovim_completion_error", "Neovim command-line completion failed", false)
  end
  return candidates, nil
end

function M.complete(request, emit, done)
  local active = true
  local snapshot = snapshot_from_request(request)
  if snapshot.status ~= "ok" then
    vim.schedule(function()
      if active then
        done(nil)
      end
    end)
    return {
      cancel = function()
        active = false
      end,
    }
  end

  local completion_type = base_type(snapshot.completion_type)
  if
    snapshot.category == "path"
    and (
      completion_type == "file"
      or completion_type == "dir"
      or completion_type == "file_in_path"
      or completion_type == "dir_in_path"
    )
  then
    return path_complete(request, snapshot, emit, done)
  end

  vim.schedule(function()
    if not active then
      return
    end
    local candidates, err = fixed_candidates(snapshot)
    if err ~= nil then
      done(err)
      return
    end
    local items = {}
    local seen = {}
    for _, candidate in ipairs(candidates) do
      if type(candidate) == "string" and not seen[candidate] then
        seen[candidate] = true
        items[#items + 1] = {
          id = "neovim:" .. snapshot.completion_type .. ":" .. candidate,
          label = candidate,
          insert_text = cmdline.encode(candidate, snapshot),
          kind = snapshot.category,
          source_order = #items + 1,
          data = {
            completion_type = snapshot.completion_type,
            logical_insert_text = candidate,
          },
        }
      end
    end
    emit(items, { is_incomplete = false })
    done(nil)
  end)

  return {
    cancel = function()
      active = false
    end,
  }
end

function M.request(context, options)
  options = options or {}
  local cwd = options.cwd or vim.uv.cwd() or vim.fn.getcwd()
  return {
    api_version = 1,
    category = context.category,
    query = context.query,
    source_text = context.source_text,
    cursor_byte = context.cursor_byte,
    replacement = context.replacement,
    cwd = cwd,
    case_mode = options.case_mode,
    matching_style = options.matching_style,
    allow_subsequence = options.allow_subsequence == true,
    limit = options.limit,
    provider = "neovim",
    context = {
      cmdline = context,
      home = options.home,
      env = options.env,
      platform = options.platform,
      filesystem_case_sensitive = options.filesystem_case_sensitive,
      search_roots = options.search_roots,
    },
  }
end

return M
