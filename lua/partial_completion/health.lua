local config = require("partial_completion.config")

local M = {}

local adapters = {
  { name = "Telescope", runtime = "lua/telescope/init.lua" },
  { name = "Blink", runtime = "lua/blink/cmp/init.lua" },
  { name = "nvim-cmp", runtime = "lua/cmp/init.lua" },
}

local function add(results, status, name, message)
  results[#results + 1] = {
    status = status,
    name = name,
    message = message,
  }
end

function M.report(overrides)
  overrides = overrides or {}
  local completion = require("partial_completion")
  local snapshot = overrides.snapshot or completion._health_snapshot()
  local has_version = overrides.has_version
  if has_version == nil then
    has_version = vim.fn.has("nvim-0.12") == 1
  end
  local runtime_files = overrides.runtime_files
    or function(path)
      return vim.api.nvim_get_runtime_file(path, false)
    end

  local results = {}
  if has_version then
    add(results, "ok", "neovim", "Neovim 0.12 or newer")
  else
    add(results, "error", "neovim", "partial-completion requires Neovim 0.12 or newer")
  end

  local valid, err = pcall(config.resolve, snapshot.config)
  if valid and snapshot.last_config_error == nil then
    add(results, "ok", "configuration", "active configuration is valid")
  else
    add(results, "error", "configuration", snapshot.last_config_error or tostring(err))
  end
  add(
    results,
    "info",
    "native",
    snapshot.native_enabled and "native command-line adapter is enabled" or "native command-line adapter is disabled"
  )

  for _, adapter in ipairs(adapters) do
    local found = runtime_files(adapter.runtime)
    add(
      results,
      "info",
      "adapter:" .. adapter.name,
      type(found) == "table" and #found > 0 and "optional host is available" or "optional host is not installed"
    )
  end
  return results
end

function M.check()
  vim.health.start("partial-completion")
  for _, item in ipairs(M.report()) do
    vim.health[item.status](item.name .. ": " .. item.message)
  end
end

return M
