local root = vim.fn.getcwd()
local output = vim.fn.tempname()
local buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buffer)

local job
local cleaned = false
local function cleanup()
  if cleaned then
    return
  end
  cleaned = true
  if type(job) == "number" and job > 0 and vim.fn.jobwait({ job }, 0)[1] == -1 then
    pcall(vim.fn.jobstop, job)
    vim.fn.jobwait({ job }, 1000)
  end
  pcall(vim.fn.delete, output)
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  once = true,
  callback = cleanup,
})

job = vim.fn.jobstart({
  vim.v.progpath,
  "-u",
  root .. "/tests/minimal_init.lua",
  "-i",
  "NONE",
  "-c",
  "lua dofile(" .. string.format("%q", root .. "/scripts/interactive_cmdline_smoke.lua") .. ")",
}, {
  term = true,
  env = {
    PARTIAL_COMPLETION_SMOKE_OUTPUT = output,
    PARTIAL_COMPLETION_SMOKE_INJECT_WARNING = vim.env.PARTIAL_COMPLETION_SMOKE_INJECT_WARNING or "",
  },
})
assert(job > 0, "failed to start the PTY Neovim child")

local function screen()
  return table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
end

local function wait_for(predicate, message)
  assert(vim.wait(5000, predicate, 10), message .. "\n" .. screen())
end

local function send(keys)
  assert(vim.fn.chansend(job, keys) > 0, "failed to send PTY input")
end

wait_for(function()
  return string.find(screen(), "~", 1, true) ~= nil
end, "PTY Neovim did not draw its initial screen")

send(":set wildm")
wait_for(function()
  local text = screen()
  return string.find(text, "wildmenu", 1, true) ~= nil and string.find(text, "wildmode", 1, true) ~= nil
end, "native candidates were not rendered in the PTY")
vim.wait(100)
send("\t\25")
vim.wait(100)
send("\27")

send(":set wildm")
wait_for(function()
  return string.find(screen(), "wildmenu", 1, true) ~= nil
end, "native candidates did not reopen")
vim.wait(100)
send("\5\27")

send(":set wildm\6")
vim.wait(100)
send(":q\r")
vim.wait(100)
send(":qa!\r")

local exited = vim.fn.jobwait({ job }, 5000)[1]
if exited == -1 then
  pcall(vim.fn.jobstop, job)
  error("PTY Neovim did not exit\n" .. screen(), 0)
end
assert(exited == 0, "PTY Neovim exited with status " .. tostring(exited) .. "\n" .. screen())
assert(vim.fn.filereadable(output) == 1, "PTY smoke did not publish state")

local state = vim.json.decode(vim.fn.readfile(output)[1])
assert(type(state) == "table" and state.capture_count > 0, "PTY smoke recorded no checkpoints")
assert(state.cmdwin_enters >= 1, "PTY smoke did not enter the command-line window")
assert(#state.async_errors == 0, "PTY smoke async errors: " .. table.concat(state.async_errors, "; "))
assert(#state.notifications == 0, "PTY smoke notifications: " .. table.concat(state.notifications, "; "))

local visible = false
local accepted_text = false
for _, checkpoint in ipairs(state.checkpoints) do
  if checkpoint.source_text == "set wildmode" then
    accepted_text = true
  end
  if checkpoint.native_visible then
    for _, label in ipairs(checkpoint.labels or {}) do
      if label == "wildmenu" or label == "wildmode" then
        visible = true
        break
      end
    end
  end
end
assert(visible, "PTY smoke never observed a visible native candidate menu")
assert(accepted_text, "PTY smoke did not observe exact accepted bytes: set wildmode")
cleanup()
io.stdout:write("Interactive PTY command-line smoke passed\n")
