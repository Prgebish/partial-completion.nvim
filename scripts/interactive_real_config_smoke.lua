local fixture = assert(vim.env.PARTIAL_COMPLETION_REAL_CONFIG_FIXTURE, "real-config fixture is required")
local output = assert(vim.env.PARTIAL_COMPLETION_REAL_CONFIG_OUTPUT, "real-config output is required")
local input_line = 's = "~/My Documents/fiZZ" tail'
local expected_line = 's = "~/My Documents/file.txt" tail'
local cursor_byte = assert(string.find(input_line, "fiZZ", 1, true)) + 1
local original_notify = vim.notify
local state = {
  accepted = false,
  exited = false,
  menu_shown = false,
  stale_checked = false,
  stale_rejected = false,
  latest_accepted = false,
  notifications = {},
  async_errors = {},
}

local function publish()
  vim.fn.writefile({ vim.json.encode(state) }, output)
end

vim.notify = function(message, level, options)
  if (level or vim.log.levels.INFO) >= vim.log.levels.WARN then
    state.notifications[#state.notifications + 1] = tostring(message)
    publish()
  end
  return original_notify(message, level, options)
end

local original_schedule = vim.schedule
local original_defer_fn = vim.defer_fn
local function guarded(callback)
  return function(...)
    local arguments = { ... }
    local ok, err = xpcall(function()
      callback(unpack(arguments))
    end, debug.traceback)
    if not ok then
      state.async_errors[#state.async_errors + 1] = tostring(err)
      publish()
    end
  end
end

vim.schedule = function(callback)
  return original_schedule(guarded(callback))
end

vim.defer_fn = function(callback, timeout)
  return original_defer_fn(guarded(callback), timeout)
end

local blink = require("blink.cmp")
local sources = require("blink.cmp.sources.lib")
local provider = sources.get_provider_by_id("partial_completion")
assert(type(provider) == "table" and type(provider.module) == "table", "real Blink source is unavailable")

vim.env.HOME = fixture
vim.cmd.cd(vim.fn.fnameescape(fixture))
local buffer = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buffer)
vim.api.nvim_buf_set_name(buffer, fixture .. "/quoted-path-smoke.py")
vim.bo[buffer].filetype = "python"
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { input_line })
vim.api.nvim_win_set_cursor(0, { 1, cursor_byte })

local function item_named(response, label)
  for _, item in ipairs(response.items or {}) do
    if item.label == label then
      return item
    end
  end
  return nil
end

local function run_stale_check()
  blink.hide()
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { input_line })
  vim.api.nvim_win_set_cursor(0, { 1, cursor_byte })
  local context = {
    mode = "default",
    bufnr = buffer,
    line = input_line,
    cursor = { 1, cursor_byte },
    get_line = function()
      return vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1]
    end,
    get_cursor = function()
      local cursor = vim.api.nvim_win_get_cursor(0)
      return { cursor[1], cursor[2] }
    end,
  }

  provider.module:get_completions(context, function(first)
    local stale_item = assert(item_named(first, "~/My Documents/file.txt"), "first ABA request returned no file")
    provider.module:get_completions(context, function(second)
      local latest_item = assert(item_named(second, "~/My Documents/file.txt"), "second ABA request returned no file")
      local stale_applied = false
      local latest_applied = false
      local resolved = 0
      provider.module:execute(context, stale_item, function()
        resolved = resolved + 1
      end, function()
        stale_applied = true
      end)
      provider.module:execute(context, latest_item, function()
        resolved = resolved + 1
      end, function()
        latest_applied = true
      end)
      state.stale_checked = resolved == 2
      state.stale_rejected = not stale_applied
      state.latest_accepted = latest_applied
      publish()
    end)
  end)
end

vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
  buffer = buffer,
  callback = function()
    local line = vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1]
    if not state.accepted and line == expected_line then
      state.accepted = true
      state.accepted_text = line
      publish()
      vim.schedule(run_stale_check)
    end
  end,
})

vim.api.nvim_create_autocmd("User", {
  pattern = "BlinkCmpShow",
  callback = function()
    local list = require("blink.cmp.completion.list")
    for index, item in ipairs(list.items or {}) do
      if item.label == "~/My Documents/file.txt" and item.source_id == "partial_completion" then
        state.menu_shown = blink.is_menu_visible()
        state.candidate_index = index
        state.candidate_label = item.label
        state.filter_text = item.filterText
        publish()
        return
      end
    end
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  once = true,
  callback = function()
    state.exited = true
    publish()
  end,
})

publish()
vim.cmd.startinsert()
vim.defer_fn(function()
  blink.show({ providers = { "partial_completion" } })
end, 50)
