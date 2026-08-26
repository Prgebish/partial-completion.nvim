local adapter = require("partial_completion.adapters")
local completion = require("partial_completion")
local config = require("partial_completion.config")

local Source = {}
Source.__index = Source
local lifecycle_events = { "InsertLeave", "CmdlineLeave", "CmdwinEnter" }
local next_source_id = 0

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
    value = ok and resolved or nil
  end
  if type(value) ~= "string" or string.sub(value, 1, 1) ~= "/" then
    value = default_cwd(context)
  end
  return value
end

local function empty_response()
  return {
    items = {},
    isIncomplete = true,
  }
end

function Source:_report(message)
  if type(self.options.on_error) == "function" then
    pcall(self.options.on_error, tostring(message))
  end
end

function Source:_cancel()
  local active = self.active
  self.active = nil
  if active ~= nil then
    active.cancelled = true
    if active.handle ~= nil then
      pcall(active.handle.cancel, active.handle)
    end
  end
end

function Source:_install_lifecycle()
  if self.lifecycle_group ~= nil then
    return
  end
  self.lifecycle_group = vim.api.nvim_create_augroup("partial_completion_cmp_" .. self.source_id, { clear = true })
  vim.api.nvim_create_autocmd(lifecycle_events, {
    group = self.lifecycle_group,
    callback = function()
      self:_cancel()
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = self.lifecycle_group,
    pattern = "CmpUnregisterSource",
    callback = function(event)
      if event.data and event.data.source_id == self.registration_id then
        self:close()
      end
    end,
  })
end

function Source.get_debug_name(_)
  return "partial-completion"
end

function Source.is_available(_)
  return true
end

function Source.get_position_encoding_kind(_)
  return "utf-8"
end

function Source.get_keyword_pattern(_)
  return [=[\%([^[:blank:]'"]\|\\[[:blank:]]\)\+]=]
end

function Source.get_trigger_characters(_)
  return { "/", ".", "\\", "~", "$" }
end

function Source:complete(params, callback)
  if type(params) ~= "table" or type(params.context) ~= "table" or type(callback) ~= "function" then
    error("nvim-cmp source requires completion params and callback", 2)
  end
  self:_cancel()
  self.generation = self.generation + 1
  local active = {
    generation = self.generation,
    cancelled = false,
    finished = false,
    handle = nil,
  }
  self.active = active

  local context = params.context
  local line = context.cursor_line
  local cursor = context.cursor
  if type(line) ~= "string" or type(cursor) ~= "table" or type(cursor.col) ~= "number" then
    active.finished = true
    self.active = nil
    callback(empty_response())
    return
  end
  local cursor_byte = cursor.col - 1
  local mode = context.mode
  if mode == nil then
    mode = vim.api.nvim_get_mode().mode == "c" and "cmdline" or "default"
  end
  if mode ~= "default" and mode ~= "cmdline" then
    active.finished = true
    self.active = nil
    callback(empty_response())
    return
  end

  local request
  local token
  local provider_active = true
  local pending_updates = {}
  local function publish(snapshot)
    if self.active ~= active or active.cancelled or active.finished then
      return
    end
    active.finished = true
    self.active = nil
    if snapshot.error ~= nil then
      self:_report(snapshot.error.message or snapshot.error.code)
      callback(empty_response())
      return
    end
    local replacement = snapshot.replacement or request.replacement
    callback({
      items = adapter.lsp_items(snapshot, {
        line = math.max((cursor.row or 1) - 1, 0),
        start_byte = replacement.start_byte,
        end_byte = replacement.end_byte,
      }, {
        filter_text = token and token.raw_query or request.query,
        insert_text = token and function(item)
          return adapter.encode_path_token(token, item.insert_text)
        end or nil,
        uniform_kind = true,
        source_text = request.source_text,
        cursor_byte = request.cursor_byte,
      }),
      isIncomplete = true,
    })
  end
  local consume = adapter.finalizer(publish)
  local function observe(update)
    if provider_active then
      pending_updates[#pending_updates + 1] = update
      return
    end
    if self.active ~= active or active.cancelled or active.finished then
      return
    end
    local ok, err = pcall(consume, update)
    if not ok then
      active.finished = true
      self.active = nil
      self:_report(err)
      callback(empty_response())
    end
  end

  local ok, result
  if mode == "cmdline" then
    request = {
      query = "",
      replacement = { start_byte = cursor_byte, end_byte = cursor_byte },
    }
    local request_options = vim.tbl_deep_extend("force", config.copy(self.options.request or {}), {
      cwd = resolve_cwd(self, context),
    })
    ok, result, request = pcall(self.complete_cmdline, line, cursor_byte, observe, request_options)
  else
    request, token = adapter.text_request(
      {
        line = line,
        cursor_byte = cursor_byte,
      },
      vim.tbl_deep_extend("force", config.copy(self.options.request or {}), {
        category = "path",
        provider = "filesystem",
        cwd = resolve_cwd(self, context),
      })
    )
    ok, result = pcall(self.complete_engine, request, observe)
  end
  provider_active = false

  if not ok then
    active.finished = true
    self.active = nil
    self:_report(result)
    callback(empty_response())
  elseif type(result) ~= "table" or type(result.cancel) ~= "function" then
    active.finished = true
    self.active = nil
    self:_report("completion returned an invalid cancel handle")
    callback(empty_response())
  else
    active.handle = result
    for _, update in ipairs(pending_updates) do
      observe(update)
      if active.finished then
        break
      end
    end
    if self.active ~= active or active.finished then
      active.handle = nil
      pcall(result.cancel, result)
    end
  end
end

function Source.resolve(_self, item, callback)
  callback(item)
end

function Source.execute(self, item, callback)
  local mode = vim.api.nvim_get_mode().mode
  local current
  if mode == "c" then
    current = {
      source_text = vim.fn.getcmdline(),
      cursor_byte = math.max(vim.fn.getcmdpos() - 1, 0),
    }
  else
    local cursor = vim.api.nvim_win_get_cursor(0)
    current = {
      source_text = vim.api.nvim_get_current_line(),
      cursor_byte = cursor[2],
    }
  end
  if not adapter.same_lsp_context(item, current) and not adapter.applied_lsp_context(item, current) then
    self:_report("stale completion context")
  end
  callback()
end

function Source:close()
  self:_cancel()
  if self.lifecycle_group ~= nil then
    pcall(vim.api.nvim_del_augroup_by_id, self.lifecycle_group)
    self.lifecycle_group = nil
  end
end

local M = {}

local function core_ordinal(entry)
  local completion_item = type(entry) == "table" and entry.completion_item or nil
  local metadata = completion_item
      and type(completion_item.data) == "table"
      and type(completion_item.data.partial_completion) == "table"
      and completion_item.data.partial_completion
    or nil
  return metadata and metadata.ordinal or nil
end

function M.compare(entry1, entry2)
  local left = core_ordinal(entry1)
  local right = core_ordinal(entry2)
  if type(left) ~= "number" or type(right) ~= "number" or left == right then
    return nil
  end
  return left < right
end

local function install_comparator(cmp)
  local current = cmp.get_config().sorting.comparators
  for _, comparator in ipairs(current) do
    if comparator == M.compare then
      return
    end
  end
  local comparators = { M.compare }
  vim.list_extend(comparators, current)
  cmp.setup({ sorting = { comparators = comparators } })
end

function M.new(options)
  if options ~= nil and type(options) ~= "table" then
    error("nvim-cmp source options must be a table", 2)
  end
  options = options or {}
  if options.get_cwd ~= nil and type(options.get_cwd) ~= "function" then
    error("nvim-cmp get_cwd must be a function", 2)
  end
  next_source_id = next_source_id + 1
  return setmetatable({
    source_id = next_source_id,
    options = config.copy(options),
    complete_engine = options.complete or completion.complete,
    complete_cmdline = options.complete_cmdline or completion.complete_cmdline,
    generation = 0,
    active = nil,
  }, Source)
end

function M.register(options)
  options = options or {}
  if type(options) ~= "table" then
    error("nvim-cmp registration options must be a table", 2)
  end
  local ok, cmp = pcall(require, "cmp")
  if not ok then
    return nil, "nvim-cmp is unavailable"
  end
  local name = options.name or "partial_completion"
  if type(name) ~= "string" or name == "" then
    error("nvim-cmp source name must be a non-empty string", 2)
  end
  local source_options = config.copy(options)
  source_options.name = nil
  install_comparator(cmp)
  local source = M.new(source_options)
  source:_install_lifecycle()
  local id = cmp.register_source(name, source)
  source.registration_id = id
  return id
end

return M
