local completion = require("partial_completion")

local state = {
  async_errors = {},
  notifications = {},
  capture_count = 0,
  cmdwin_enters = 0,
  checkpoints = {},
}

local function publish()
  vim.g.partial_completion_smoke = vim.json.encode(state)
end

local original_schedule = vim.schedule
local original_defer_fn = vim.defer_fn
local original_notify = vim.notify
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

vim.notify = function(message, level, options)
  if (level or vim.log.levels.INFO) >= vim.log.levels.WARN then
    state.notifications[#state.notifications + 1] = tostring(message)
    publish()
  end
  return original_notify(message, level, options)
end

if vim.env.PARTIAL_COMPLETION_SMOKE_INJECT_WARNING == "1" then
  vim.schedule(function()
    vim.notify("native-pty-warning-selftest-sentinel", vim.log.levels.WARN)
  end)
end

local function capture(tag)
  local session = completion.native_state()
  local checkpoint = {
    tag = tag,
    native_visible = completion.native_visible(),
    cmdtype = vim.fn.getcmdtype(),
    cmdwin = vim.fn.getcmdwintype(),
    labels = {},
  }
  if vim.fn.getcmdpos() > 0 then
    checkpoint.source_text = vim.fn.getcmdline()
    checkpoint.cursor_byte = vim.fn.getcmdpos() - 1
  end
  if session ~= nil then
    checkpoint.status = session.status
    checkpoint.generation = session.generation
    checkpoint.request_id = session.request_id
    checkpoint.selected_id = session.selected_id
    for index = 1, math.min(#session.items, 10) do
      checkpoint.labels[index] = session.items[index].label
    end
  end
  state.capture_count = state.capture_count + 1
  state.checkpoints[#state.checkpoints + 1] = checkpoint
  state.latest = checkpoint
  publish()
end

local function capture_later(tag)
  vim.defer_fn(function()
    capture(tag)
  end, 20)
end

completion.enable_native({ request = { limit = 20 } })
vim.fn.histadd("cmd", "set number")
vim.fn.setreg("q", ":let g:partial_completion_macro_smoke = 1\r")

vim.keymap.set("c", "<F6>", function()
  capture("manual")
  return ""
end, { expr = true, silent = true })

local group = vim.api.nvim_create_augroup("PartialCompletionInteractiveSmoke", { clear = true })
vim.api.nvim_create_autocmd({ "CmdlineChanged", "CursorMovedC" }, {
  group = group,
  pattern = ":",
  callback = function(args)
    capture_later(args.event)
  end,
})
vim.api.nvim_create_autocmd("CmdwinEnter", {
  group = group,
  pattern = ":",
  callback = function()
    state.cmdwin_enters = state.cmdwin_enters + 1
    capture_later("CmdwinEnter")
  end,
})
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  once = true,
  callback = function()
    completion.disable_native()
    local output = vim.env.PARTIAL_COMPLETION_SMOKE_OUTPUT
    if type(output) == "string" and output ~= "" then
      vim.fn.writefile({ vim.json.encode(state) }, output)
    end
  end,
})

publish()
