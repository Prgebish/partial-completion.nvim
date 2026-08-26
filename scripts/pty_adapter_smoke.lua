local root = vim.fn.getcwd()
local dependencies = vim.env.PARTIAL_COMPLETION_DEPS_DIR or (root .. "/deps")

local function run(adapter_name)
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

  vim.fn.mkdir(fixture .. "/Desktop/Library", "p")
  vim.fn.mkdir(fixture .. "/Desktop/Library/Unsorted", "p")
  vim.fn.mkdir(fixture .. "/Documents/lc0", "p")
  vim.fn.mkdir(fixture .. "/My Documents", "p")
  vim.fn.writefile({ "preview" }, fixture .. "/Desktop/Library/demo.txt")
  vim.fn.writefile({ "preview" }, fixture .. "/Desktop/Library/debugger-long.txt")
  vim.fn.writefile({ "preview" }, fixture .. "/Documents/lc0/uci_nodes1_proxy.py")
  vim.fn.writefile({ "preview" }, fixture .. "/My Documents/file.txt")
  vim.fn.writefile({ "preview" }, fixture .. "/My Documents/fidelity-long.txt")

  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buffer)
  local ok, err = xpcall(function()
    job = vim.fn.jobstart({
      vim.v.progpath,
      "-u",
      root .. "/tests/minimal_init.lua",
      "-i",
      "NONE",
      "--listen",
      socket,
      "-c",
      "lua dofile(" .. string.format("%q", root .. "/scripts/interactive_adapter_smoke.lua") .. ")",
    }, {
      term = true,
      env = {
        PARTIAL_COMPLETION_DEPS_DIR = dependencies,
        PARTIAL_COMPLETION_SMOKE_ADAPTER = adapter_name,
        PARTIAL_COMPLETION_SMOKE_FIXTURE = fixture,
        PARTIAL_COMPLETION_SMOKE_OUTPUT = output,
      },
    })
    assert(job > 0, "failed to start the " .. adapter_name .. " PTY Neovim child")

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
      assert(vim.wait(5000, predicate, 10), message .. "\n" .. vim.inspect(read_state()) .. "\n" .. screen())
    end

    wait_for(function()
      local state = read_state()
      if state == nil or not state.menu_shown then
        return false
      end
      if adapter_name == "blink" then
        return string.find(screen(), "Unsorted", 1, true) ~= nil
          and string.find(screen(), "uci_nodes1_proxy.py", 1, true) ~= nil
      end
      if adapter_name == "nvim_cmp" then
        return string.find(screen(), "file.txt", 1, true) ~= nil
          and string.find(screen(), "fidelity-long.txt", 1, true) ~= nil
      end
      return string.find(screen(), "demo.txt", 1, true) ~= nil
        and string.find(screen(), "debugger-long.txt", 1, true) ~= nil
    end, adapter_name .. " did not render its real completion menu")
    vim.wait(100)

    rpc = vim.fn.sockconnect("pipe", socket, { rpc = true })
    assert(rpc > 0, "failed to connect to the " .. adapter_name .. " Neovim child")
    local before_acceptance = assert(read_state(), adapter_name .. " state disappeared")
    local mapping_mode = adapter_name == "blink" and "c" or "i"
    local mappings = vim.rpcrequest(rpc, "nvim_buf_get_keymap", before_acceptance.prompt_buffer or 0, mapping_mode)
    vim.list_extend(mappings, vim.rpcrequest(rpc, "nvim_get_keymap", mapping_mode))
    local current_buffer = vim.rpcrequest(rpc, "nvim_get_current_buf")
    local mapped = false
    for _, mapping in ipairs(mappings) do
      if mapping.lhs == "<Tab>" or mapping.lhs == "<C-I>" then
        mapped = true
        break
      end
    end
    assert(mapped, adapter_name .. " acceptance mapping was not installed: " .. vim.inspect(mappings))
    assert(
      before_acceptance.prompt_buffer == nil or current_buffer == before_acceptance.prompt_buffer,
      adapter_name
        .. " prompt is not current: expected "
        .. tostring(before_acceptance.prompt_buffer)
        .. ", got "
        .. tostring(current_buffer)
    )
    local acceptance_key = vim.rpcrequest(rpc, "nvim_replace_termcodes", "<Tab>", true, false, true)
    vim.rpcrequest(rpc, "nvim_feedkeys", acceptance_key, "m", false)
    wait_for(function()
      local state = read_state()
      return state ~= nil and state.accepted
    end, adapter_name .. " did not accept the selected completion")

    vim.rpcnotify(rpc, "nvim_command", "qa!")
    local exited = vim.fn.jobwait({ job }, 5000)[1]
    if exited == -1 then
      error(adapter_name .. " PTY Neovim did not exit\n" .. screen(), 0)
    end
    assert(exited == 0, adapter_name .. " PTY Neovim exited with status " .. tostring(exited) .. "\n" .. screen())

    local state = assert(read_state(), adapter_name .. " PTY smoke did not publish state")
    assert(state.exited, adapter_name .. " PTY smoke did not observe clean exit")
    assert(#state.notifications == 0, adapter_name .. " emitted warnings: " .. table.concat(state.notifications, "; "))
    assert(#state.async_errors == 0, adapter_name .. " async errors: " .. table.concat(state.async_errors, "; "))
    if adapter_name == "telescope" then
      local expected_path = vim.uv.fs_realpath(fixture .. "/Desktop/Library/demo.txt")
        or (fixture .. "/Desktop/Library/demo.txt")
      assert(state.accepted_text == expected_path, "Telescope accepted the wrong path")
    else
      local expected = adapter_name == "blink" and "edit ~/Documents/lc0/uci_nodes1_proxy.py"
        or 's = "My Documents/file.txt" tail'
      assert(state.accepted_text == expected, adapter_name .. " applied the wrong text edit")
    end
    if adapter_name == "blink" then
      assert(state.first_label == "~/Documents/lc0/uci_nodes1_proxy.py", "Blink rendered the wrong first cmdline item")
      assert(
        vim.deep_equal(state.core_spans, { { 0, 1 }, { 2, 3 }, { 12, 13 }, { 16, 17 } }),
        "Blink item lost core cmdline spans: " .. vim.inspect(state.core_spans)
      )
      assert(
        vim.deep_equal(state.highlight_spans, { { 0, 1 }, { 2, 3 }, { 12, 13 }, { 16, 17 } }),
        "Blink did not render every core match span: " .. vim.inspect(state.highlight_spans)
      )
    end
  end, debug.traceback)
  cleanup()
  if not ok then
    error(err, 0)
  end
  io.stdout:write("Interactive PTY adapter smoke passed: " .. adapter_name .. "\n")
end

for _, adapter_name in ipairs({ "telescope", "blink", "nvim_cmp" }) do
  run(adapter_name)
end
