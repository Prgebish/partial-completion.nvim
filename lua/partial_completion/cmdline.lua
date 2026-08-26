local session = require("partial_completion.session")
local utf8 = require("partial_completion.utf8")

local M = {}

local category_by_type = {
  file = "path",
  dir = "path",
  file_in_path = "path",
  dir_in_path = "path",
  command = "command",
  option = "option",
  buffer = "buffer",
  help = "help",
  ["function"] = "function",
  var = "variable",
  mapping = "mapping",
  menu = "mapping",
}

local filename_types = {
  file = true,
  dir = true,
  file_in_path = true,
  dir_in_path = true,
  arglist = true,
  diff_buffer = true,
}

local escaped_filename_bytes

local controller_counter = 0

local function integer(value)
  return type(value) == "number" and value % 1 == 0
end

local function base_completion_type(completion_type)
  return string.match(completion_type or "", "^([^,]+)") or ""
end

function M.category_for(completion_type)
  return category_by_type[base_completion_type(completion_type)] or "generic"
end

local function is_escaped(text, byte_index)
  local slashes = 0
  local index = byte_index - 1
  while index >= 1 and string.byte(text, index) == 92 do
    slashes = slashes + 1
    index = index - 1
  end
  return slashes % 2 == 1
end

local function scan_start(prefix)
  local index = #prefix
  while index >= 1 do
    local byte = string.byte(prefix, index)
    if (byte == 9 or byte == 32 or byte == 124) and not is_escaped(prefix, index) then
      break
    end
    index = index - 1
  end
  return index
end

local function scan_end(source_text, cursor_byte)
  local index = cursor_byte + 1
  while index <= #source_text do
    local byte = string.byte(source_text, index)
    if (byte == 9 or byte == 32 or byte == 124) and not is_escaped(source_text, index) then
      break
    end
    index = index + 1
  end
  return index - 1
end

local function pattern_start(source_text, cursor_byte, pattern)
  if pattern == nil or pattern == "" then
    return nil
  end
  local search_from = 1
  local selected
  while true do
    local first, last = string.find(source_text, pattern, search_from, true)
    if first == nil then
      break
    end
    local start_byte = first - 1
    if start_byte <= cursor_byte and last >= cursor_byte then
      selected = start_byte
    end
    search_from = first + 1
  end
  return selected
end

local function fnameescape_bytes()
  if escaped_filename_bytes ~= nil then
    return escaped_filename_bytes
  end
  escaped_filename_bytes = {}
  for byte = 1, 127 do
    local character = string.char(byte)
    local escaped = "\\" .. character
    for _, sample in ipairs({ character, character .. "x", "x" .. character, "x" .. character .. "x" }) do
      if string.find(vim.fn.fnameescape(sample), escaped, 1, true) ~= nil then
        escaped_filename_bytes[byte] = true
        break
      end
    end
  end
  return escaped_filename_bytes
end

local function decode_query(raw)
  local escapable = fnameescape_bytes()
  local result = {}
  local index = 1
  while index <= #raw do
    local byte = string.byte(raw, index)
    local next_byte = string.byte(raw, index + 1)
    if byte == 92 and next_byte ~= nil and escapable[next_byte] then
      result[#result + 1] = string.char(next_byte)
      index = index + 2
    else
      result[#result + 1] = string.sub(raw, index, index)
      index = index + 1
    end
  end
  return table.concat(result)
end

local function preserve_environment_root(text, platform)
  local separator = platform == "windows" and "[\\/]" or "/"
  local root, rest = string.match(text, "^(%$[A-Za-z_][A-Za-z0-9_]*" .. separator .. ")(.*)$")
  if root ~= nil then
    return root, rest
  end
  root, rest = string.match(text, "^(%${[A-Za-z_][A-Za-z0-9_]*}" .. separator .. ")(.*)$")
  if root ~= nil then
    return root, rest
  end
  return "", text
end

function M.encode(text, context)
  local completion_type = base_completion_type(context.completion_type)
  if context.category == "path" or context.category == "buffer" or filename_types[completion_type] then
    local root, rest = preserve_environment_root(text, context.platform)
    return root .. vim.fn.fnameescape(rest)
  end
  return text
end

local function live_values(source_text, cursor_byte)
  local cmdpos = vim.fn.getcmdpos()
  if cmdpos < 1 or vim.fn.getcmdline() ~= source_text or cmdpos - 1 ~= cursor_byte then
    return nil
  end
  return {
    completion_type = vim.fn.getcmdcompltype(),
    completion_pattern = vim.fn.getcmdcomplpat(),
    cmdtype = vim.fn.getcmdtype(),
  }
end

function M.analyze(source_text, cursor_byte, options)
  options = options or {}
  if type(source_text) ~= "string" or not utf8.is_valid(source_text) then
    error("command line must be valid UTF-8", 2)
  end
  if not integer(cursor_byte) or not utf8.is_boundary(source_text, cursor_byte) then
    error("command-line cursor must be a UTF-8 byte boundary", 2)
  end

  local prefix = string.sub(source_text, 1, cursor_byte)
  local live = options.live == false and nil or live_values(source_text, cursor_byte)
  local ok, inferred_type = pcall(vim.fn.getcompletiontype, prefix)
  if not ok then
    inferred_type = ""
  end
  local completion_type = options.completion_type
    or (live and live.completion_type ~= "" and live.completion_type)
    or inferred_type
    or ""
  local completion_pattern = options.completion_pattern or (live and live.completion_pattern) or ""
  local cmdtype = options.cmdtype or (live and live.cmdtype) or ":"
  local start_byte = pattern_start(source_text, cursor_byte, completion_pattern) or scan_start(prefix)

  local base_type = base_completion_type(completion_type)
  if base_type == "shellcmd" and string.sub(source_text, start_byte + 1, start_byte + 1) == "!" then
    start_byte = start_byte + 1
  end
  local end_byte = scan_end(source_text, cursor_byte)
  local raw_query = string.sub(source_text, start_byte + 1, cursor_byte)
  local context = {
    status = cmdtype == ":" and "ok" or "unsupported",
    source_text = source_text,
    cursor_byte = cursor_byte,
    prefix = prefix,
    completion_base = string.sub(source_text, 1, start_byte),
    completion_pattern = completion_pattern,
    completion_type = completion_type,
    category = M.category_for(completion_type),
    query = decode_query(raw_query),
    raw_query = raw_query,
    replacement = { start_byte = start_byte, end_byte = end_byte },
    cmdtype = cmdtype,
    cmdlevel = options.cmdlevel,
    generation = options.generation,
  }
  if context.status == "unsupported" then
    context.reason = "unsupported_cmdline_type"
  end
  return context
end

function M.capture(options)
  options = options or {}
  local position = vim.fn.getcmdpos()
  if position < 1 then
    return {
      status = "unsupported",
      reason = "not_editing_cmdline",
      cmdtype = vim.fn.getcmdtype(),
      cmdlevel = options.cmdlevel,
      generation = options.generation,
    }
  end
  options.cmdtype = options.cmdtype or vim.fn.getcmdtype()
  return M.analyze(vim.fn.getcmdline(), position - 1, options)
end

function M.apply_edit(source_text, replacement, insert_text)
  if
    type(source_text) ~= "string"
    or type(insert_text) ~= "string"
    or not utf8.is_valid(source_text)
    or not utf8.is_valid(insert_text)
    or type(replacement) ~= "table"
    or not integer(replacement.start_byte)
    or not integer(replacement.end_byte)
    or replacement.start_byte > replacement.end_byte
    or not utf8.is_boundary(source_text, replacement.start_byte)
    or not utf8.is_boundary(source_text, replacement.end_byte)
  then
    error("invalid command-line edit", 2)
  end
  local line = string.sub(source_text, 1, replacement.start_byte)
    .. insert_text
    .. string.sub(source_text, replacement.end_byte + 1)
  return line, replacement.start_byte + #insert_text
end

function M.accept(item, snapshot, live)
  if type(item) ~= "table" or type(item.insert_text) ~= "string" or not utf8.is_valid(item.insert_text) then
    return nil, "invalid_item"
  end
  if not session.same_context(snapshot, live) then
    return nil, "stale_context"
  end
  local line, cursor_byte = M.apply_edit(snapshot.source_text, snapshot.replacement, item.insert_text)
  return {
    status = "accepted",
    source_text = line,
    cursor_byte = cursor_byte,
  }
end

local Controller = {}
Controller.__index = Controller

local function event_level(fallback)
  local event = vim.v.event
  if type(event) == "table" and type(event.cmdlevel) == "number" then
    return event.cmdlevel
  end
  return fallback or 1
end

function Controller:_cancel(level)
  local state = self.levels[level]
  if state ~= nil then
    if state.session ~= nil then
      state.session:cancel("context_cancelled")
      state.session = nil
    elseif state.handle ~= nil then
      state.handle:cancel()
    end
    state.handle = nil
    state.cancelled = true
  end
end

function Controller:request(context, level)
  level = level or self.active_level or 1
  if self.active_level ~= nil and self.active_level ~= level then
    self:_cancel(self.active_level)
  end
  self:_cancel(level)
  self.generation = self.generation + 1
  context.generation = self.generation
  context.cmdlevel = level
  self.active_level = level
  local state = {
    generation = self.generation,
    context = context,
    cancelled = false,
    handle = nil,
    session = nil,
  }
  self.levels[level] = state
  if self.on_context ~= nil then
    self.on_context(context)
  end
  if
    self.levels[level] ~= state
    or self.active_level ~= level
    or state.cancelled
    or self.generation ~= state.generation
  then
    return nil
  end
  if context.status ~= "ok" then
    return nil
  end

  local generation = state.generation
  local request_session = session.new({
    complete = self.complete,
    on_change = function(snapshot, event, update)
      local current = self.levels[level]
      if
        current == state
        and self.active_level == level
        and session.should_observe(current.generation, current.cancelled, generation)
      then
        if self.on_state ~= nil then
          self.on_state(snapshot, context, event)
        end
        if event == "update" then
          self.on_update(update, context, snapshot)
        end
      end
    end,
    on_error = self.on_error,
  })
  request_session.generation = generation - 1
  state.session = request_session
  state.handle = request_session
  request_session:start(context)
  return request_session
end

function Controller:refresh(reason)
  if self.applying_accept ~= nil then
    return nil
  end
  local level = self.active_level or 1
  local context = M.capture({ cmdlevel = level })
  context.reason = reason or context.reason
  return self:request(context, level)
end

function Controller:accept(item)
  local level = self.active_level
  local state = level and self.levels[level] or nil
  if vim.fn.getcmdwintype() ~= "" then
    return nil, "unsupported_cmdwin"
  end
  if state == nil then
    return nil, "no_active_context"
  end
  if state.session == nil then
    return nil, "no_active_session"
  end
  return state.session:accept(function(selected)
    local live = M.capture({ cmdlevel = level, generation = state.generation })
    local result, err = M.accept(selected, state.context, live)
    if result == nil then
      if err == "stale_context" then
        self:refresh("stale_context")
      end
      return nil, err
    end
    self.applying_accept = state
    local applied = vim.fn.setcmdline(result.source_text, result.cursor_byte + 1)
    if self.applying_accept == state then
      self.applying_accept = nil
    end
    if applied ~= 0 then
      return nil, "cmdline_unavailable"
    end
    return result
  end, item)
end

function Controller:select(index_or_id, source)
  local state = self.active_level and self.levels[self.active_level] or nil
  if state == nil or state.session == nil then
    return nil, "no_active_session"
  end
  return state.session:select(index_or_id, source)
end

function Controller:select_next(delta)
  local state = self.active_level and self.levels[self.active_level] or nil
  if state == nil or state.session == nil then
    return nil, "no_active_session"
  end
  return state.session:select_next(delta)
end

function Controller:selected_item()
  local state = self.active_level and self.levels[self.active_level] or nil
  return state and state.session and state.session:selected_item() or nil
end

function Controller:state()
  local state = self.active_level and self.levels[self.active_level] or nil
  return state and state.session and state.session:snapshot() or nil
end

function Controller:cancel(reason)
  local state = self.active_level and self.levels[self.active_level] or nil
  if state == nil or state.session == nil then
    return nil, "no_active_session"
  end
  state.session:cancel(reason or "user_cancelled")
  state.session = nil
  state.handle = nil
  state.cancelled = true
  return true
end

function Controller:start()
  if self.group ~= nil then
    return self
  end
  controller_counter = controller_counter + 1
  self.group = vim.api.nvim_create_augroup("PartialCompletionCmdline" .. controller_counter, { clear = true })
  vim.api.nvim_create_autocmd("CmdlineEnter", {
    group = self.group,
    pattern = ":",
    callback = function()
      local level = event_level((self.active_level or 0) + 1)
      if self.active_level ~= nil then
        self:_cancel(self.active_level)
      end
      self.active_level = level
      self:refresh("enter")
    end,
  })
  vim.api.nvim_create_autocmd({ "CmdlineChanged", "CursorMovedC" }, {
    group = self.group,
    pattern = ":",
    callback = function(args)
      self:refresh(args.event)
    end,
  })
  vim.api.nvim_create_autocmd("CmdlineLeavePre", {
    group = self.group,
    pattern = ":",
    callback = function()
      self:_cancel(self.active_level)
    end,
  })
  vim.api.nvim_create_autocmd("CmdlineLeave", {
    group = self.group,
    pattern = ":",
    callback = function()
      local level = event_level(self.active_level)
      self:_cancel(level)
      self.levels[level] = nil
      local previous
      for candidate_level in pairs(self.levels) do
        if previous == nil or candidate_level > previous then
          previous = candidate_level
        end
      end
      self.active_level = previous
    end,
  })
  vim.api.nvim_create_autocmd("CmdwinEnter", {
    group = self.group,
    callback = function()
      for level in pairs(self.levels) do
        self:_cancel(level)
      end
      self.active_level = nil
    end,
  })
  return self
end

function Controller:stop()
  for level in pairs(self.levels) do
    self:_cancel(level)
  end
  self.levels = {}
  self.active_level = nil
  if self.group ~= nil then
    pcall(vim.api.nvim_del_augroup_by_id, self.group)
    self.group = nil
  end
end

function M.new_controller(options)
  if type(options) ~= "table" or type(options.complete) ~= "function" then
    error("command-line controller requires complete callback", 2)
  end
  return setmetatable({
    complete = options.complete,
    on_update = options.on_update or function() end,
    on_state = options.on_state,
    on_context = options.on_context,
    on_error = options.on_error,
    levels = {},
    active_level = nil,
    generation = 0,
    group = nil,
    applying_accept = nil,
  }, Controller)
end

return M
