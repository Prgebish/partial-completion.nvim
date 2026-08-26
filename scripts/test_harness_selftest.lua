local runner = require("tests.helpers.runner")
local mode = assert(arg[1], "self-test mode is required")

local load_sources = {
  empty_file = "return {}",
  load_warning = [[
vim.notify("load_warning-selftest-sentinel", vim.log.levels.WARN)
return {{ name = "load warning", run = function() end }}
]],
  load_scheduled = [[
vim.schedule(function() error("load_scheduled-selftest-sentinel") end)
return {{ name = "load scheduled", run = function() end }}
]],
  load_timer = [[
local timer = vim.uv.new_timer()
timer:start(10000, 0, function() end)
return {{ name = "load timer", run = function() end }}
]],
}

if load_sources[mode] ~= nil then
  local root = vim.fn.stdpath("state") .. "/partial-completion-selftest"
  vim.fn.mkdir(root, "p")
  local file = root .. "/" .. mode .. ".lua"
  vim.fn.writefile(vim.split(load_sources[mode], "\n", { plain = true }), file)
  runner.run({
    label = "Harness load self-test",
    files = { file },
    drain_timeout_ms = 20,
  })
  return
end

if mode == "mapping_changed" then
  vim.keymap.set("n", "<F12>", "before")
end

local tests = {
  scheduled = function()
    vim.schedule(function()
      error("scheduled-selftest-sentinel")
    end)
  end,
  warning = function()
    vim.schedule(function()
      vim.notify("warning-selftest-sentinel", vim.log.levels.WARN)
    end)
  end,
  leak = function()
    local timer = vim.uv.new_timer()
    timer:start(10000, 0, function() end)
  end,
  inactive_timer = function()
    vim.uv.new_timer()
  end,
  raw_fd = function()
    local root = vim.fn.stdpath("state") .. "/partial-completion-selftest"
    vim.fn.mkdir(root, "p")
    assert(vim.uv.fs_open(root .. "/raw-fd", "w", 384))
  end,
  mapping_local = function()
    vim.keymap.set("n", "<F11>", "local", { buffer = 0 })
  end,
  mapping_changed = function()
    vim.keymap.set("n", "<F12>", "after")
  end,
}

runner.run({
  label = "Harness self-test",
  tests = {
    {
      name = mode,
      run = assert(tests[mode], "unknown self-test mode: " .. mode),
    },
  },
  drain_timeout_ms = 20,
})
