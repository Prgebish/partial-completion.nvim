local M = {}

local function traceback(message)
  return debug.traceback(tostring(message), 2)
end

local function handle_resources()
  local resources = {
    handles = {},
    descriptors = {},
    timers = {},
    processes = {},
  }
  vim.uv.walk(function(handle)
    local closing = handle:is_closing()
    if not closing then
      local description = tostring(handle)
      resources.handles[handle] = description
      local type_ok, handle_type = pcall(handle.get_type, handle)
      handle_type = type_ok and tostring(handle_type) or description
      if handle_type == "timer" or string.find(handle_type, "timer", 1, true) then
        resources.timers[handle] = description
      elseif handle_type == "process" or string.find(handle_type, "process", 1, true) then
        resources.processes[handle] = description
      end
      local fd_ok, descriptor = pcall(handle.fileno, handle)
      if fd_ok and descriptor ~= nil then
        resources.descriptors[tostring(descriptor) .. "\0" .. description] = true
      end
    end
  end)
  return resources
end

local function active_handles()
  return handle_resources().handles
end

local function os_descriptors()
  local root = vim.fn.isdirectory("/proc/self/fd") == 1 and "/proc/self/fd"
    or (vim.fn.isdirectory("/dev/fd") == 1 and "/dev/fd" or nil)
  local descriptors = {}
  if root ~= nil then
    for _, descriptor in ipairs(vim.fn.readdir(root)) do
      if string.match(descriptor, "^%d+$") then
        if root == "/proc/self/fd" then
          -- Linux may include the short-lived descriptor used to enumerate
          -- /proc/self/fd itself. Depending on the libc implementation it may
          -- already be closed or still point back to this process's fd root.
          local target = vim.uv.fs_readlink(root .. "/" .. descriptor)
          local own_root = "/proc/" .. tostring(vim.uv.os_getpid()) .. "/fd"
          if target ~= nil and target ~= root and target ~= own_root then
            descriptors[descriptor .. " -> " .. target] = true
          end
        else
          descriptors[descriptor] = true
        end
      end
    end
  end
  return descriptors
end

local function pending_filesystem_requests()
  local ok, filesystem = pcall(require, "partial_completion.providers.filesystem")
  return ok and filesystem.pending_request_count() or 0
end

local function resource_snapshot()
  local buffers = {}
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buffer) then
      buffers[buffer] = true
    end
  end

  local windows = {}
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(window) then
      windows[window] = true
    end
  end

  local autocmds = {}
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({})) do
    local key = autocmd.id
      or table.concat({
        tostring(autocmd.event),
        tostring(autocmd.group or autocmd.group_name),
        tostring(autocmd.pattern),
        tostring(autocmd.command),
      }, "\0")
    autocmds[key] = true
  end

  local mappings = {}
  local function add_mapping(scope, mode, mapping)
    local fields = {
      scope,
      mode,
      tostring(mapping.lhs or ""),
      tostring(mapping.rhs or ""),
      tostring(mapping.callback or ""),
      tostring(mapping.desc or ""),
      tostring(mapping.expr or 0),
      tostring(mapping.noremap or 0),
      tostring(mapping.nowait or 0),
      tostring(mapping.silent or 0),
      tostring(mapping.script or 0),
      tostring(mapping.sid or 0),
      tostring(mapping.lnum or 0),
      tostring(mapping.replace_keycodes or 0),
    }
    mappings[table.concat(fields, "\0")] = true
  end
  for _, mode in ipairs({ "n", "i", "c", "v", "x", "s", "o", "t", "l" }) do
    for _, mapping in ipairs(vim.api.nvim_get_keymap(mode)) do
      add_mapping("global", mode, mapping)
    end
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buffer) then
        local ok, buffer_mappings = pcall(vim.api.nvim_buf_get_keymap, buffer, mode)
        if ok then
          for _, mapping in ipairs(buffer_mappings) do
            add_mapping("buffer:" .. buffer, mode, mapping)
          end
        end
      end
    end
  end

  local namespaces = {}
  for name, namespace in pairs(vim.api.nvim_get_namespaces()) do
    namespaces[name .. "\0" .. tostring(namespace)] = true
  end
  local current_handles = handle_resources()
  local pending_requests = {}
  local pending_count = pending_filesystem_requests()
  for index = 1, pending_count do
    pending_requests[index] = true
  end

  return {
    buffers = buffers,
    windows = windows,
    handles = current_handles.handles,
    descriptors = current_handles.descriptors,
    os_descriptors = os_descriptors(),
    timers = current_handles.timers,
    processes = current_handles.processes,
    pending_requests = pending_requests,
    autocmds = autocmds,
    mappings = mappings,
    namespaces = namespaces,
  }
end

local function added_keys(before, after)
  local added = {}
  for key in pairs(after) do
    if before[key] == nil then
      added[#added + 1] = tostring(key)
    end
  end
  table.sort(added)
  return added
end

local function resource_errors(before, after, options)
  options = options or {}
  local errors = {}
  local buffers = added_keys(before.buffers, after.buffers)
  local windows = added_keys(before.windows, after.windows)
  local handles = added_keys(before.handles, after.handles)
  local descriptors = added_keys(before.descriptors, after.descriptors)
  local os_descriptor_keys = added_keys(before.os_descriptors, after.os_descriptors)
  local timers = added_keys(before.timers, after.timers)
  local processes = added_keys(before.processes, after.processes)
  local pending_requests = added_keys(before.pending_requests, after.pending_requests)
  local autocmds = added_keys(before.autocmds, after.autocmds)
  local mappings = added_keys(before.mappings, after.mappings)
  local namespaces = added_keys(before.namespaces, after.namespaces)
  if type(options.allowed_namespaces) == "table" and #namespaces > 0 then
    local allowed = {}
    for _, name in ipairs(options.allowed_namespaces) do
      allowed[name] = true
    end
    local filtered = {}
    for _, key in ipairs(namespaces) do
      local separator = string.find(key, "\0", 1, true)
      local name = separator and string.sub(key, 1, separator - 1) or key
      if not allowed[name] then
        filtered[#filtered + 1] = key
      end
    end
    namespaces = filtered
  end
  if #buffers > 0 then
    errors[#errors + 1] = "leaked buffers: " .. table.concat(buffers, ", ")
  end
  if #windows > 0 then
    errors[#errors + 1] = "leaked windows: " .. table.concat(windows, ", ")
  end
  if #handles > 0 then
    errors[#errors + 1] = "leaked libuv handles: " .. table.concat(handles, ", ")
  end
  if #descriptors > 0 then
    errors[#errors + 1] = "leaked file descriptors: " .. table.concat(descriptors, ", ")
  end
  if #os_descriptor_keys > 0 then
    errors[#errors + 1] = "leaked OS file descriptors: " .. table.concat(os_descriptor_keys, ", ")
  end
  if #timers > 0 then
    errors[#errors + 1] = "leaked timers: " .. table.concat(timers, ", ")
  end
  if #processes > 0 then
    errors[#errors + 1] = "leaked background processes: " .. table.concat(processes, ", ")
  end
  if #pending_requests > 0 then
    errors[#errors + 1] = "leaked pending filesystem requests: " .. table.concat(pending_requests, ", ")
  end
  if #autocmds > 0 then
    errors[#errors + 1] = "leaked autocmds: " .. table.concat(autocmds, ", ")
  end
  if #mappings > 0 then
    errors[#errors + 1] = "leaked mappings: " .. table.concat(mappings, ", ")
  end
  if #namespaces > 0 then
    errors[#errors + 1] = "leaked namespaces: " .. table.concat(namespaces, ", ")
  end
  return errors
end

local function discover(patterns)
  local files = {}
  for _, pattern in ipairs(patterns) do
    vim.list_extend(files, vim.fn.glob(pattern, false, true))
  end
  table.sort(files)
  return files
end

local function load_tests(files)
  local tests = {}
  for _, file in ipairs(files) do
    local loaded = dofile(file)
    assert(type(loaded) == "table", "test file must return a table: " .. file)
    assert(#loaded > 0, "test file returned no tests: " .. file)
    for _, test in ipairs(loaded) do
      assert(type(test) == "table", "invalid test entry in " .. file)
      assert(type(test.name) == "string" and test.name ~= "", "test requires a name: " .. file)
      assert(type(test.run) == "function", "test requires run(): " .. test.name)
      tests[#tests + 1] = test
    end
  end
  return tests
end

function M.run(options)
  options = options or {}
  local files = options.files or discover(options.patterns or {})
  local original_schedule = vim.schedule
  local original_notify = vim.notify
  local pending_scheduled = 0
  local active_failures
  local orphan_failures = {}

  local function record(message)
    local failures = active_failures or orphan_failures
    failures[#failures + 1] = tostring(message)
  end

  vim.schedule = function(callback)
    assert(type(callback) == "function", "vim.schedule callback must be a function")
    pending_scheduled = pending_scheduled + 1
    return original_schedule(function()
      local ok, err = xpcall(callback, traceback)
      pending_scheduled = pending_scheduled - 1
      if not ok then
        record("scheduled callback failed:\n" .. tostring(err))
      end
    end)
  end

  vim.notify = function(message, level, options_table)
    level = level or vim.log.levels.INFO
    if level >= vim.log.levels.WARN then
      record(
        string.format("unexpected %s: %s", level >= vim.log.levels.ERROR and "error" or "warning", tostring(message))
      )
    end
    return original_notify(message, level, options_table)
  end

  -- Neovim lazily opens its process-owned temporary root on the first
  -- tempname() call. Prime it before the resource baseline so a test that
  -- merely requests a temporary path is not blamed for Neovim's lifetime fd.
  vim.fn.tempname()
  local suite_before = resource_snapshot()
  local tests = options.tests or load_tests(files)
  local minimum_files = options.minimum_files or 1
  local minimum_tests = options.minimum_tests or 1
  if options.required_files ~= nil then
    local discovered = {}
    for _, file in ipairs(files) do
      discovered[file] = true
    end
    for _, file in ipairs(options.required_files) do
      assert(discovered[file], "required test file was not discovered: " .. file)
    end
  end
  assert(
    #files >= minimum_files or options.tests ~= nil,
    string.format("discovered %d test files; need %d", #files, minimum_files)
  )
  assert(#tests >= minimum_tests, string.format("discovered %d tests; need %d", #tests, minimum_tests))

  local function drain(before)
    local settled = vim.wait(options.drain_timeout_ms or 3000, function()
      local current = active_handles()
      local current_os_descriptors = os_descriptors()
      return pending_scheduled == 0
        and #added_keys(before.handles, current) == 0
        and #added_keys(before.os_descriptors, current_os_descriptors) == 0
        and pending_filesystem_requests() <= vim.tbl_count(before.pending_requests)
    end, 1)
    if not settled then
      record("async work did not settle before the test timeout")
    end

    local sentinel = false
    original_schedule(function()
      sentinel = true
    end)
    if not vim.wait(1000, function()
      return sentinel
    end, 1) then
      record("scheduled work did not reach the drain sentinel")
    end
  end

  local failures = {}
  local prefix = options.output_prefix or ""
  if options.tests == nil then
    drain(suite_before)
    vim.list_extend(
      orphan_failures,
      resource_errors(suite_before, resource_snapshot(), {
        allowed_namespaces = options.allowed_load_namespaces,
      })
    )
  end
  for index, test in ipairs(tests) do
    local before = resource_snapshot()
    active_failures = {}
    local ok, err = xpcall(test.run, traceback)
    if not ok then
      active_failures[#active_failures + 1] = tostring(err)
    end
    drain(before)
    vim.list_extend(active_failures, resource_errors(before, resource_snapshot()))
    if #active_failures == 0 then
      io.stdout:write(string.format("ok %d - %s%s\n", index, prefix, test.name))
    else
      failures[#failures + 1] = test.name .. "\n" .. table.concat(active_failures, "\n")
      io.stdout:write(string.format("not ok %d - %s%s\n", index, prefix, test.name))
    end
    active_failures = nil
  end

  local final_sentinel = false
  original_schedule(function()
    final_sentinel = true
  end)
  vim.wait(1000, function()
    return final_sentinel
  end, 1)
  vim.schedule = original_schedule
  vim.notify = original_notify

  vim.list_extend(failures, orphan_failures)
  io.stdout:write(string.format("1..%d\n", #tests))
  if #failures > 0 then
    error(table.concat(failures, "\n\n"), 0)
  end
  io.stdout:write(string.format("%s passed: %d\n", options.label or "Tests", #tests))
end

return M
