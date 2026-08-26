local adapter = require("partial_completion.adapters")
local completion = require("partial_completion")
local config = require("partial_completion.config")
local utf8 = require("partial_completion.utf8")

local M = {}
local Source = {}
Source.__index = Source
local wrapped_highlights = setmetatable({}, { __mode = "k" })

local function integer(value)
  return type(value) == "number" and value % 1 == 0
end

local function core_spans(context)
  local metadata = type(context) == "table"
      and type(context.item) == "table"
      and type(context.item.data) == "table"
      and type(context.item.data.partial_completion) == "table"
      and context.item.data.partial_completion
    or nil
  local label = type(context) == "table" and context.label or nil
  if metadata == nil or type(metadata.spans) ~= "table" or type(label) ~= "string" then
    return nil
  end

  local spans = {}
  local previous_end = 0
  for _, span in ipairs(metadata.spans) do
    if
      type(span) ~= "table"
      or not integer(span[1])
      or not integer(span[2])
      or span[1] < previous_end
      or span[1] >= span[2]
      or span[2] > #label
      or not utf8.is_boundary(label, span[1])
      or not utf8.is_boundary(label, span[2])
    then
      return nil
    end
    spans[#spans + 1] = { span[1], span[2] }
    previous_end = span[2]
  end
  return spans
end

local function host_spans(context)
  local label = type(context) == "table" and context.label or nil
  if type(label) ~= "string" then
    return {}
  end
  local spans = {}
  local indices = type(context.label_matched_indices) == "table" and context.label_matched_indices or {}
  for _, index in ipairs(indices) do
    if integer(index) and index >= 0 and index < #label then
      spans[#spans + 1] = { index, index + 1 }
    end
  end
  return spans
end

local function default_label_highlight(context)
  local label = type(context.label) == "string" and context.label or ""
  local label_detail = type(context.label_detail) == "string" and context.label_detail or ""
  local highlights = {
    {
      0,
      #label,
      group = context.deprecated and "BlinkCmpLabelDeprecated" or "BlinkCmpLabel",
    },
  }
  if label_detail ~= "" then
    highlights[#highlights + 1] = {
      #label,
      #label + #label_detail,
      group = "BlinkCmpLabelDetail",
    }
  end
  for _, span in ipairs(host_spans(context)) do
    highlights[#highlights + 1] = {
      span[1],
      span[2],
      group = "BlinkCmpLabelMatch",
    }
  end
  return highlights
end

local function evaluate_highlight(highlight, context, text)
  if type(highlight) == "function" then
    return highlight(context, text)
  end
  return highlight
end

local function replace_match_highlights(highlight, context, text)
  local original = evaluate_highlight(highlight, context, text)
  if type(text) == "string" then
    local label = type(context.label) == "string" and context.label or ""
    local detail = type(context.label_detail) == "string" and context.label_detail or ""
    local expected = label .. detail
    local padding = string.sub(text, #expected + 1)
    if string.sub(text, 1, #expected) ~= expected or string.find(padding, "[^ ]") then
      return original
    end
  end
  local spans = core_spans(context)
  if spans == nil then
    return original
  end

  local highlights = {}
  if type(original) == "string" then
    highlights[1] = { group = original }
  elseif type(original) == "table" then
    for _, entry in ipairs(original) do
      if type(entry) ~= "table" or entry.group ~= "BlinkCmpLabelMatch" then
        highlights[#highlights + 1] = entry
      end
    end
  end
  for _, span in ipairs(spans) do
    highlights[#highlights + 1] = {
      span[1],
      span[2],
      group = "BlinkCmpLabelMatch",
    }
  end
  return highlights
end

local function default_cwd(context)
  if type(context.bufnr) == "number" and vim.api.nvim_buf_is_valid(context.bufnr) then
    local name = vim.api.nvim_buf_get_name(context.bufnr)
    if name ~= "" then
      return vim.fs.dirname(name)
    end
  end
  return vim.uv.cwd() or vim.fn.getcwd()
end

local function resolve_cwd(self, context)
  local value = self.options.get_cwd or self.options.cwd
  if type(value) == "function" then
    local ok, resolved = pcall(value, context)
    if ok then
      value = resolved
    else
      value = nil
    end
  end
  if type(value) ~= "string" or string.sub(value, 1, 1) ~= "/" then
    value = default_cwd(context)
  end
  return value
end

local function empty_response()
  return {
    items = {},
    is_incomplete_forward = true,
    is_incomplete_backward = true,
  }
end

function Source:_report(message)
  if type(self.options.on_error) == "function" then
    pcall(self.options.on_error, tostring(message))
  end
end

function Source.get_trigger_characters(_)
  return { "/", ".", "\\", "~", "$" }
end

function Source.enabled(_)
  return true
end

function Source:get_completions(context, callback)
  if type(context) ~= "table" or type(callback) ~= "function" then
    error("Blink source requires a context and callback", 2)
  end
  local mode = context.mode or "default"
  if mode ~= "default" and mode ~= "cmdline" then
    callback(empty_response())
    return function() end
  end

  self.request_epoch = self.request_epoch + 1
  local request_epoch = self.request_epoch
  self.current_fingerprint = nil

  local cancelled = false
  local finished = false
  local handle
  local request
  local token
  local provider_active = true
  local pending_updates = {}
  local line = context.line
  local cursor = context.cursor
  if type(line) ~= "string" or type(cursor) ~= "table" or type(cursor[2]) ~= "number" then
    callback(empty_response())
    return function() end
  end

  local function publish(snapshot)
    if cancelled or finished then
      return
    end
    finished = true
    if snapshot.error ~= nil then
      self:_report(snapshot.error.message or snapshot.error.code)
      callback(empty_response())
      return
    end
    local replacement = snapshot.replacement or request.replacement
    local row = mode == "cmdline" and 0 or math.max((cursor[1] or 1) - 1, 0)
    local source_text = request.source_text or line
    local cursor_byte = request.cursor_byte or cursor[2]
    if self.request_epoch == request_epoch then
      self.current_fingerprint = {
        request_id = snapshot.request_id,
        generation = snapshot.generation,
        source_text = source_text,
        cursor_byte = cursor_byte,
        replacement = config.copy(replacement),
      }
    end
    callback({
      items = adapter.lsp_items(snapshot, {
        line = row,
        start_byte = replacement.start_byte,
        end_byte = replacement.end_byte,
      }, {
        filter_text = token and token.raw_query or request.query,
        insert_text = token and function(item)
          return adapter.encode_path_token(token, item.insert_text)
        end or nil,
        source_text = source_text,
        cursor_byte = cursor_byte,
      }),
      is_incomplete_forward = true,
      is_incomplete_backward = true,
    })
  end
  local consume = adapter.finalizer(publish)
  local function observe(update)
    if provider_active then
      pending_updates[#pending_updates + 1] = update
      return
    end
    if cancelled or finished then
      return
    end
    local ok, err = pcall(consume, update)
    if not ok then
      finished = true
      self:_report(err)
      callback(empty_response())
    end
  end

  local ok, result
  if mode == "cmdline" then
    request = {
      query = "",
      replacement = { start_byte = cursor[2], end_byte = cursor[2] },
    }
    local request_options = vim.tbl_deep_extend("force", config.copy(self.options.request or {}), {
      cwd = resolve_cwd(self, context),
    })
    ok, result, request = pcall(self.complete_cmdline, line, cursor[2], observe, request_options)
  else
    local bounds = self.options.use_context_bounds and context.bounds or nil
    request, token = adapter.text_request(
      {
        line = line,
        cursor_byte = cursor[2],
        start_byte = bounds and bounds.start_col - 1 or nil,
        end_byte = bounds and bounds.start_col + bounds.length - 1 or nil,
      },
      vim.tbl_deep_extend("force", config.copy(self.options.request or {}), {
        category = "path",
        provider = "filesystem",
        cwd = resolve_cwd(self, context),
      })
    )
    ok, result = pcall(self.complete, request, observe)
  end
  provider_active = false

  if not ok then
    finished = true
    self:_report(result)
    callback(empty_response())
  elseif type(result) ~= "table" or type(result.cancel) ~= "function" then
    finished = true
    self:_report("completion returned an invalid cancel handle")
    callback(empty_response())
  else
    handle = result
    for _, update in ipairs(pending_updates) do
      observe(update)
      if finished then
        break
      end
    end
    if finished then
      pcall(handle.cancel, handle)
      handle = nil
    end
  end

  return function()
    if cancelled then
      return
    end
    cancelled = true
    if self.request_epoch == request_epoch then
      self.current_fingerprint = nil
    end
    if handle ~= nil then
      pcall(handle.cancel, handle)
      handle = nil
    end
  end
end

function Source:execute(context, item, resolve, default_implementation)
  local line = context and context.line
  local cursor = context and context.cursor
  if context and type(context.get_line) == "function" then
    local ok, live_line = pcall(context.get_line)
    line = ok and live_line or nil
  end
  if context and type(context.get_cursor) == "function" then
    local ok, live_cursor = pcall(context.get_cursor)
    cursor = ok and live_cursor or nil
  end
  local current = config.copy(self.current_fingerprint or {})
  current.source_text = line
  current.cursor_byte = cursor and cursor[2]
  if self.current_fingerprint == nil or not adapter.same_lsp_context(item, current) then
    self:_report("stale completion context")
    resolve()
    return
  end
  default_implementation()
  resolve()
end

function M.label_highlight(context, text)
  if type(context) ~= "table" then
    return {}
  end
  return replace_match_highlights(default_label_highlight, context, text)
end

function M.wrap_label_highlight(highlight)
  local wrapper = function(context, text)
    return replace_match_highlights(highlight, context, text)
  end
  wrapped_highlights[wrapper] = true
  return wrapper
end

function M.install_label_highlight()
  local ok, blink_config = pcall(require, "blink.cmp.config")
  local component = ok
      and type(blink_config.completion) == "table"
      and type(blink_config.completion.menu) == "table"
      and type(blink_config.completion.menu.draw) == "table"
      and type(blink_config.completion.menu.draw.components) == "table"
      and blink_config.completion.menu.draw.components.label
    or nil
  if type(component) ~= "table" then
    return false, "Blink label component is unavailable"
  end
  if component.highlight == M.label_highlight or wrapped_highlights[component.highlight] then
    return true
  end
  component.highlight = M.wrap_label_highlight(component.highlight)
  return true
end

function M.new(options)
  if options ~= nil and type(options) ~= "table" then
    error("Blink source options must be a table", 2)
  end
  options = options or {}
  if options.get_cwd ~= nil and type(options.get_cwd) ~= "function" then
    error("Blink get_cwd must be a function", 2)
  end
  if options.auto_highlight ~= nil and type(options.auto_highlight) ~= "boolean" then
    error("Blink auto_highlight must be a boolean", 2)
  end
  if options.auto_highlight ~= false then
    M.install_label_highlight()
  end
  return setmetatable({
    options = config.copy(options),
    complete = options.complete or completion.complete,
    complete_cmdline = options.complete_cmdline or completion.complete_cmdline,
    request_epoch = 0,
    current_fingerprint = nil,
  }, Source)
end

return M
