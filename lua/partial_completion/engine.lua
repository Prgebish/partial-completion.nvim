local config_module = require("partial_completion.config")
local logger = require("partial_completion.logger")
local matcher = require("partial_completion.matcher")
local types = require("partial_completion.types")

local M = {}
M.__index = M

function M.new(config, providers)
  return setmetatable({
    config = config,
    providers = providers,
    next_request_id = 0,
  }, M)
end

function M:set_config(config)
  self.config = config
end

local function copy_replacement(replacement)
  return replacement and {
    start_byte = replacement.start_byte,
    end_byte = replacement.end_byte,
  } or nil
end

local function safe_text(value)
  local ok, result = pcall(tostring, value)
  return ok and result or "<unprintable provider value>"
end

local function rank_filtered(candidates)
  local ranked = {}
  for _, candidate in ipairs(candidates) do
    local item = config_module.copy(candidate)
    item._case_mode = nil
    ranked[#ranked + 1] = item
  end
  table.sort(ranked, function(left, right)
    if left.source_order ~= right.source_order then
      return left.source_order < right.source_order
    end
    if left.label ~= right.label then
      return left.label < right.label
    end
    return left.id < right.id
  end)
  for index, item in ipairs(ranked) do
    item.match = {
      level = "provider",
      score = #ranked - index + 1,
      spans = {},
    }
  end
  return ranked
end

function M:complete(input_request, callback)
  if type(callback) ~= "function" then
    error("completion callback must be a function", 2)
  end

  local config_snapshot = config_module.copy(self.config)
  local request = types.validate_request(input_request, config_snapshot)
  local request_profile = config_module.profile_for(config_snapshot, request, request.query)
  request.case_mode = request_profile.case_mode
  request.matching_style = request_profile.matching_style
  self.next_request_id = self.next_request_id + 1
  request.request_id = self.next_request_id
  request.generation = self.next_request_id

  local provider_name, provider_error = self.providers:resolve(request)
  if provider_name == nil then
    error(provider_error, 2)
  end
  local provider = self.providers.by_name[provider_name]
  local provider_metadata = self.providers.metadata[provider_name] or {}
  local started_at = vim.uv.hrtime()
  if logger.enabled() then
    logger.debug("request_started", {
      request_id = request.request_id,
      generation = request.generation,
      category = request.category,
      provider = provider_name,
      query = request.query,
      cwd = request.cwd,
    })
  end

  local state = {
    active = true,
    done = false,
    is_incomplete = false,
    next_source_order = 0,
    source_orders = {},
    items = {},
    provider_handle = nil,
    resolved_case_mode = nil,
    consumer_error = nil,
    provider_call_active = true,
    provider_failed = false,
  }

  local function cancel_provider()
    local handle = state.provider_handle
    state.provider_handle = nil
    if handle ~= nil then
      pcall(handle.cancel, handle)
    end
  end

  local function consumer_failed(err)
    if state.consumer_error ~= nil then
      return
    end
    state.consumer_error = tostring(err)
    state.active = false
    state.done = true
    cancel_provider()
    if not state.provider_call_active then
      local message = state.consumer_error
      vim.schedule(function()
        error("completion callback failed: " .. message, 0)
      end)
    end
  end

  local function snapshot(done, err)
    local candidates = {}
    for _, item in pairs(state.items) do
      candidates[#candidates + 1] = item
    end
    local ranking_request = request
    if state.resolved_case_mode ~= nil then
      ranking_request = config_module.copy(request)
      ranking_request.case_mode = state.resolved_case_mode
    end
    local profile = config_module.profile_for(config_snapshot, ranking_request, request.query)
    local ranked = provider_metadata.already_filtered and rank_filtered(candidates)
      or matcher.rank(request.query, candidates, profile)
    local limited = {}
    for index = 1, math.min(#ranked, request.limit) do
      limited[index] = config_module.copy(ranked[index])
      limited[index]._case_mode = nil
    end

    local ok, callback_error = pcall(callback, {
      api_version = 1,
      request_id = request.request_id,
      generation = request.generation,
      replacement = copy_replacement(request.replacement),
      items = limited,
      is_incomplete = state.is_incomplete or #ranked > request.limit,
      done = done,
      error = err,
    })
    if not ok then
      consumer_failed(callback_error)
    end
  end

  local done

  local function process_emit(items, metadata)
    if not state.active or state.done then
      return
    end
    if type(items) ~= "table" then
      error("provider items must be a table")
    end
    if metadata ~= nil and type(metadata) ~= "table" then
      error("provider metadata must be a table")
    end
    metadata = metadata or {}
    if metadata.replace == true then
      state.items = {}
      state.is_incomplete = metadata.is_incomplete == true
    else
      state.is_incomplete = state.is_incomplete or metadata.is_incomplete == true
    end
    if
      request.case_mode == "filesystem"
      and (metadata.resolved_case_mode == "sensitive" or metadata.resolved_case_mode == "insensitive")
    then
      state.resolved_case_mode = metadata.resolved_case_mode
    end

    for _, item in ipairs(items) do
      state.next_source_order = state.next_source_order + 1
      local normalized_ok, normalized = pcall(types.normalize_item, item, provider_name, state.next_source_order)
      if normalized_ok and normalized ~= nil then
        local key = provider_name .. "\0" .. normalized.id
        if state.source_orders[key] == nil then
          state.source_orders[key] = normalized.source_order
        else
          normalized.source_order = state.source_orders[key]
        end
        state.items[key] = normalized
      else
        state.is_incomplete = true
      end
    end
    if logger.enabled() then
      logger.debug("provider_emitted", {
        request_id = request.request_id,
        provider = provider_name,
        item_count = #items,
        retained_count = vim.tbl_count(state.items),
        incomplete = state.is_incomplete,
      })
    end
    snapshot(false, nil)
  end

  local function emit(items, metadata)
    local ok, failure = pcall(process_emit, items, metadata)
    if not ok and state.active and not state.done then
      state.provider_failed = true
      cancel_provider()
      done(types.error("invalid_provider_emission", safe_text(failure), false))
    end
  end

  local function finish(err)
    if not state.active or state.done then
      return
    end
    local normalized_error
    if err ~= nil then
      if type(err) == "table" and type(err.code) == "string" and err.code ~= "" then
        local message = err.message == nil and err.code or err.message
        normalized_error = types.error(err.code, safe_text(message), err.transient)
      else
        normalized_error = types.error("provider_error", safe_text(err), false)
      end
    end
    state.done = true
    if logger.enabled() then
      logger.debug("request_finished", {
        request_id = request.request_id,
        provider = provider_name,
        item_count = vim.tbl_count(state.items),
        incomplete = state.is_incomplete,
        error_code = normalized_error and normalized_error.code or nil,
        elapsed_ms = (vim.uv.hrtime() - started_at) / 1000000,
      })
    end
    snapshot(true, normalized_error)
    state.active = false
    state.provider_handle = nil
  end

  done = function(err)
    local ok, failure = pcall(finish, err)
    if not ok and state.active and not state.done then
      state.provider_failed = true
      cancel_provider()
      local recovered = pcall(finish, types.error("provider_error", safe_text(failure), false))
      if not recovered then
        state.active = false
        state.done = true
      end
    end
  end

  local ok, provider_handle = pcall(provider.complete, request, emit, done)
  state.provider_call_active = false
  if state.consumer_error ~= nil then
    if provider_handle ~= nil and type(provider_handle) == "table" and type(provider_handle.cancel) == "function" then
      pcall(provider_handle.cancel, provider_handle)
    end
    error("completion callback failed: " .. state.consumer_error, 2)
  end
  if not ok then
    done(types.error("provider_error", safe_text(provider_handle), false))
  elseif state.active and (type(provider_handle) ~= "table" or type(provider_handle.cancel) ~= "function") then
    done(types.error("invalid_provider_handle", "provider returned an invalid cancel handle", false))
  elseif state.active then
    state.provider_handle = provider_handle
  elseif state.provider_failed and type(provider_handle) == "table" and type(provider_handle.cancel) == "function" then
    pcall(provider_handle.cancel, provider_handle)
  end

  return {
    cancel = function()
      if not state.active then
        return
      end
      state.active = false
      if logger.enabled() then
        logger.debug("request_cancelled", {
          request_id = request.request_id,
          provider = provider_name,
          elapsed_ms = (vim.uv.hrtime() - started_at) / 1000000,
        })
      end
      cancel_provider()
    end,
  }
end

return M
