local M = {}

local Native = {}
Native.__index = Native

local mapping_actions = { "next", "previous", "accept", "cancel" }
local message_id = "partial-completion.native"
local namespace = vim.api.nvim_create_namespace(message_id)

local function keycode(keys)
  return vim.api.nvim_replace_termcodes(keys, true, false, true)
end

local function valid_buffer(buffer)
  return buffer ~= nil and vim.api.nvim_buf_is_valid(buffer)
end

local function valid_window(window)
  return window ~= nil and vim.api.nvim_win_is_valid(window)
end

local function selected_index(state)
  for index, item in ipairs(state.items) do
    if item.id == state.selected_id and item.source == state.selected_source then
      return index
    end
  end
  return 1
end

local function truncate(text, max_width)
  if vim.fn.strdisplaywidth(text) <= max_width then
    return text
  end
  local characters = vim.fn.strchars(text)
  while characters > 0 do
    local prefix = vim.fn.strcharpart(text, 0, characters)
    if vim.fn.strdisplaywidth(prefix .. "…") <= max_width then
      return prefix .. "…"
    end
    characters = characters - 1
  end
  return ""
end

local function sanitize(text)
  return string.gsub(text, "[%z\1-\31\127]", " ")
end

local function append(chunks, text, group)
  if text ~= "" then
    chunks[#chunks + 1] = { text, group }
  end
end

local function append_label(chunks, label, spans, selected)
  local base_group = selected and "PmenuSel" or "Pmenu"
  local match_group = selected and "PmenuMatchSel" or "PmenuMatch"
  local cursor = 0
  for _, span in ipairs(spans or {}) do
    if span[1] >= cursor and span[1] < #label and span[2] <= #label then
      append(chunks, string.sub(label, cursor + 1, span[1]), base_group)
      append(chunks, string.sub(label, span[1] + 1, span[2]), match_group)
      cursor = span[2]
    end
  end
  append(chunks, string.sub(label, cursor + 1), base_group)
end

function Native:_restore_mappings()
  if self.saved_mappings == nil then
    return
  end
  for lhs, mapping in pairs(self.saved_mappings) do
    pcall(vim.keymap.del, "c", lhs)
    if type(mapping) == "table" and next(mapping) ~= nil then
      pcall(vim.fn.mapset, "c", false, mapping)
    end
  end
  self.saved_mappings = nil
end

function Native:_mapping(action, lhs)
  if vim.fn.reg_executing() ~= "" or vim.fn.reg_recording() ~= "" or not self:is_visible() then
    return keycode(lhs)
  end
  if action == "next" then
    self.controller:select_next(1)
    return ""
  end
  if action == "previous" then
    self.controller:select_next(-1)
    return ""
  end
  if action == "accept" then
    local result = self.controller:accept()
    return result and "" or keycode(lhs)
  end
  self.controller:cancel("native_cancel")
  return keycode(lhs)
end

function Native:_install_mappings()
  if self.saved_mappings ~= nil then
    return
  end
  self.saved_mappings = {}
  for _, action in ipairs(mapping_actions) do
    local lhs = self.config.mappings[action]
    if lhs ~= false then
      self.saved_mappings[lhs] = vim.fn.maparg(lhs, "c", false, true)
      vim.keymap.set("c", lhs, function()
        return self:_mapping(action, lhs)
      end, {
        expr = true,
        silent = true,
        replace_keycodes = false,
        desc = "partial-completion native " .. action,
      })
    end
  end
end

function Native:_visible_items(state)
  local selected = selected_index(state)
  local first = math.max(1, selected - self.config.max_items + 1)
  if #state.items - first + 1 < self.config.max_items then
    first = math.max(1, #state.items - self.config.max_items + 1)
  end
  local last = math.min(#state.items, first + self.config.max_items - 1)
  local result = {}
  for index = first, last do
    result[#result + 1] = {
      item = state.items[index],
      selected = index == selected,
    }
  end
  return result
end

function Native:_ensure_buffer()
  if valid_buffer(self.buffer) then
    return self.buffer
  end
  self.buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buffer].bufhidden = "hide"
  vim.bo[self.buffer].buftype = "nofile"
  vim.bo[self.buffer].swapfile = false
  vim.bo[self.buffer].modifiable = false
  return self.buffer
end

local function window_config()
  return {
    relative = "editor",
    row = math.max(0, vim.o.lines - vim.o.cmdheight - 1),
    col = 0,
    width = math.max(1, vim.o.columns),
    height = 1,
    focusable = false,
    noautocmd = true,
    style = "minimal",
    zindex = 250,
  }
end

function Native:_ensure_window()
  local config = window_config()
  if valid_window(self.window) then
    vim.api.nvim_win_set_config(self.window, config)
    vim.wo[self.window].winblend = vim.o.pumblend
    return self.window
  end
  self.window = vim.api.nvim_open_win(self:_ensure_buffer(), false, config)
  vim.wo[self.window].winhighlight = "Normal:Pmenu,NormalFloat:Pmenu"
  vim.wo[self.window].winblend = vim.o.pumblend
  vim.wo[self.window].wrap = false
  return self.window
end

function Native:render(state, context)
  self.current_state = state
  self.current_context = context
  if
    not self.enabled
    or type(state) ~= "table"
    or state.status ~= "active"
    or type(state.items) ~= "table"
    or #state.items == 0
    or type(context) ~= "table"
    or context.cmdtype ~= ":"
    or vim.fn.getcmdwintype() ~= ""
  then
    self:close_menu()
    return
  end

  local chunks = {}
  local used_width = 0
  for _, entry in ipairs(self:_visible_items(state)) do
    local label = truncate(sanitize(entry.item.label), self.config.max_width)
    local detail = entry.item.detail and truncate(sanitize(entry.item.detail), math.max(1, self.config.max_width / 2))
      or ""
    local candidate_width = vim.fn.strdisplaywidth(label) + vim.fn.strdisplaywidth(detail) + (detail ~= "" and 3 or 2)
    local separator_width = #chunks > 0 and 1 or 0
    if #chunks > 0 and used_width + separator_width + candidate_width > vim.o.columns then
      break
    end
    if #chunks > 0 then
      append(chunks, " ", "Pmenu")
      used_width = used_width + 1
    end
    local base_group = entry.selected and "PmenuSel" or "Pmenu"
    append(chunks, " ", base_group)
    append_label(chunks, label, entry.item.match and entry.item.match.spans, entry.selected)
    if detail ~= "" then
      append(chunks, "  " .. detail, base_group)
    end
    append(chunks, " ", base_group)
    used_width = used_width + candidate_width
  end
  if state.is_incomplete and used_width + 2 <= vim.o.columns then
    append(chunks, " …", "PmenuKind")
  end
  if used_width < self.config.min_width then
    append(chunks, string.rep(" ", self.config.min_width - used_width), "Pmenu")
  end

  local text = {}
  for _, chunk in ipairs(chunks) do
    text[#text + 1] = chunk[1]
  end
  text = table.concat(text)
  local buffer = self:_ensure_buffer()
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { text })
  vim.api.nvim_buf_clear_namespace(buffer, self.namespace, 0, -1)
  local column = 0
  for _, chunk in ipairs(chunks) do
    local next_column = column + #chunk[1]
    if next_column > column and chunk[2] ~= nil then
      vim.api.nvim_buf_set_extmark(buffer, self.namespace, 0, column, {
        end_col = next_column,
        hl_group = chunk[2],
        priority = 100,
      })
    end
    column = next_column
  end
  vim.bo[buffer].modifiable = false

  self.last_chunks = vim.deepcopy(chunks)
  self:_ensure_window()
  self.message_visible = true
  self:_install_mappings()
  pcall(vim.cmd.redraw)
end

function Native:queue_render(state, context)
  self.render_token = self.render_token + 1
  local token = self.render_token
  state = vim.deepcopy(state)
  context = vim.deepcopy(context)
  vim.defer_fn(function()
    if not self.enabled or self.render_token ~= token then
      return
    end
    local ok, err = pcall(self.render, self, state, context)
    if not ok then
      self:close_menu()
      if self.on_error ~= nil then
        self.on_error(err)
      end
    end
  end, 0)
end

function Native:is_visible()
  return self.message_visible == true and valid_window(self.window)
end

function Native:close_menu()
  if valid_window(self.window) then
    local window = self.window
    if vim.fn.getcmdwintype() == "" then
      pcall(vim.api.nvim_win_close, window, true)
    else
      pcall(vim.api.nvim_buf_set_lines, self.buffer, 0, -1, false, { "" })
      pcall(vim.api.nvim_set_option_value, "winblend", 100, { win = window })
      pcall(vim.api.nvim_win_set_config, window, {
        relative = "editor",
        row = vim.o.lines,
        col = vim.o.columns,
        width = 1,
        height = 1,
      })
      vim.api.nvim_create_autocmd("CmdwinLeave", {
        once = true,
        callback = function()
          vim.schedule(function()
            if valid_window(window) then
              pcall(vim.api.nvim_win_close, window, true)
            end
          end)
        end,
      })
    end
  end
  self.window = nil
  self.message_visible = false
  self.last_chunks = nil
  self:_restore_mappings()
  pcall(vim.cmd.redraw)
end

function Native:start()
  if self.enabled then
    return self
  end
  self.enabled = true
  self.controller:start()
  return self
end

function Native:stop()
  if not self.enabled then
    return self
  end
  self.enabled = false
  self.render_token = self.render_token + 1
  self.controller:stop()
  self:close_menu()
  if valid_buffer(self.buffer) then
    pcall(vim.api.nvim_buf_delete, self.buffer, { force = true })
  end
  self.buffer = nil
  self.current_state = nil
  self.current_context = nil
  return self
end

function Native:state()
  return self.controller:state()
end

function Native:select_next(delta)
  return self.controller:select_next(delta)
end

function Native:accept()
  return self.controller:accept()
end

function Native:cancel()
  return self.controller:cancel("native_cancel")
end

function M.new(options)
  if type(options) ~= "table" or type(options.new_controller) ~= "function" or type(options.config) ~= "table" then
    error("native adapter requires config and controller factory", 2)
  end
  local self = setmetatable({
    config = options.config,
    enabled = false,
    on_error = options.on_error,
    render_token = 0,
    namespace = namespace,
  }, Native)
  self.controller = options.new_controller({
    request = self.config.request,
    on_state = function(state, context)
      self:queue_render(state, context)
    end,
    on_error = options.on_error,
  })
  return self
end

return M
