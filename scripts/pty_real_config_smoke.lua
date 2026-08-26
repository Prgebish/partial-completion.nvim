local root = vim.fn.getcwd()
local user_init = vim.env.PARTIAL_COMPLETION_USER_INIT or vim.fn.expand("~/.config/nvim/init.lua")
assert(vim.fn.filereadable(user_init) == 1, "user init.lua is unavailable: " .. user_init)

local output = vim.fn.tempname()
local fixture = vim.fn.tempname()
local socket = vim.fn.tempname()
local job
local rpc

local function cleanup()
  if type(rpc) == "number" and rpc > 0 then
    pcall(vim.rpcnotify, rpc, "nvim_command", "qa!")
  end
  if type(job) == "number" and job > 0 then
    local status = vim.fn.jobwait({ job }, 100)[1]
    if status == -1 then
      local pid = vim.fn.jobpid(job)
      pcall(vim.fn.jobstop, job)
      status = vim.fn.jobwait({ job }, 500)[1]
      if status == -1 and type(pid) == "number" and pid > 0 then
        pcall(vim.uv.kill, pid, 9)
        vim.fn.jobwait({ job }, 1000)
      end
    end
  end
  if type(rpc) == "number" and rpc > 0 then
    pcall(vim.fn.chanclose, rpc)
  end
  pcall(vim.fn.delete, output)
  pcall(vim.fn.delete, fixture, "rf")
  pcall(vim.fn.delete, socket)
end

vim.fn.mkdir(fixture .. "/My Documents", "p")
vim.fn.mkdir(fixture .. "/state", "p")
vim.fn.mkdir(fixture .. "/cache", "p")
vim.fn.writefile({ "fixture" }, fixture .. "/My Documents/file.txt")
vim.fn.writefile({ "fixture" }, fixture .. "/My Documents/fidelity-long.txt")

local buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buffer)
local ok, err = xpcall(function()
  job = vim.fn.jobstart({
    vim.v.progpath,
    "-u",
    user_init,
    "-i",
    "NONE",
    "--listen",
    socket,
    "-c",
    "lua dofile(" .. string.format("%q", root .. "/scripts/interactive_real_config_smoke.lua") .. ")",
  }, {
    term = true,
    env = {
      PARTIAL_COMPLETION_REAL_CONFIG_FIXTURE = fixture,
      PARTIAL_COMPLETION_REAL_CONFIG_OUTPUT = output,
      XDG_STATE_HOME = fixture .. "/state",
      XDG_CACHE_HOME = fixture .. "/cache",
    },
  })
  assert(job > 0, "failed to start real-config PTY Neovim")

  local function screen()
    return table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
  end

  local function read_state()
    if vim.fn.filereadable(output) ~= 1 then
      return nil
    end
    local lines = vim.fn.readfile(output)
    if #lines == 0 then
      return nil
    end
    local decoded, value = pcall(vim.json.decode, lines[1])
    return decoded and value or nil
  end

  local function wait_for(predicate, message)
    assert(vim.wait(10000, predicate, 10), message .. "\n" .. vim.inspect(read_state()) .. "\n" .. screen())
  end

  wait_for(function()
    local state = read_state()
    return state ~= nil
      and state.menu_shown
      and type(state.candidate_index) == "number"
      and string.find(screen(), "file.txt", 1, true) ~= nil
  end, "real user config did not render quoted-path completion")

  rpc = vim.fn.sockconnect("pipe", socket, { rpc = true })
  assert(rpc > 0, "failed to connect to real-config PTY Neovim")
  local before = assert(read_state(), "real-config state disappeared")
  local accepted = vim.rpcrequest(
    rpc,
    "nvim_exec_lua",
    "return require('blink.cmp').accept({ index = ... })",
    { before.candidate_index }
  )
  assert(accepted == true, "real Blink refused the selected quoted-path item")

  wait_for(function()
    local state = read_state()
    return state ~= nil and state.accepted and state.stale_checked
  end, "real user config did not finish acceptance and stale-item checks")

  vim.rpcnotify(rpc, "nvim_command", "qa!")
  local exited = vim.fn.jobwait({ job }, 5000)[1]
  if exited == -1 then
    error("real-config PTY Neovim did not exit\n" .. screen(), 0)
  end
  assert(exited == 0, "real-config PTY Neovim exited with status " .. tostring(exited) .. "\n" .. screen())

  local state = assert(read_state(), "real-config PTY smoke did not publish state")
  assert(state.exited, "real-config PTY smoke did not observe clean exit")
  assert(state.accepted_text == 's = "~/My Documents/file.txt" tail', "real Blink applied the wrong quoted edit")
  assert(state.stale_rejected, "real Blink accepted an ABA-stale item")
  assert(state.latest_accepted, "real Blink rejected the current item")
  assert(#state.notifications == 0, "real config emitted warnings: " .. table.concat(state.notifications, "; "))
  assert(#state.async_errors == 0, "real config async errors: " .. table.concat(state.async_errors, "; "))
end, debug.traceback)

cleanup()
if not ok then
  error(err, 0)
end
io.stdout:write("Interactive PTY real-user-config smoke passed: quoted path and ABA stale rejection\n")
