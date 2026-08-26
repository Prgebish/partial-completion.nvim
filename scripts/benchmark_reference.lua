local completion = require("partial_completion")

local query = assert(vim.env.PARTIAL_COMPLETION_REFERENCE_QUERY, "PARTIAL_COMPLETION_REFERENCE_QUERY is required")
assert(query ~= "", "PARTIAL_COMPLETION_REFERENCE_QUERY is required")
local home = vim.env.PARTIAL_COMPLETION_REFERENCE_HOME or vim.env.HOME
local runs = tonumber(vim.env.PARTIAL_COMPLETION_REFERENCE_RUNS) or 6
assert(runs > 0 and runs % 1 == 0, "PARTIAL_COMPLETION_REFERENCE_RUNS must be a positive integer")

completion.setup({
  filesystem = {
    cache = { max_entries = 128, max_bytes = 8 * 1024 * 1024, ttl_ms = 60000 },
  },
})

local function measure()
  local started = vim.uv.hrtime()
  local result = { updates = 0 }
  local handle = completion.complete({
    category = "path",
    query = query,
    cwd = assert(vim.uv.cwd()),
    context = { home = home },
    limit = 100,
  }, function(update)
    result.updates = result.updates + 1
    if result.first_ms == nil and #update.items > 0 then
      result.first_ms = (vim.uv.hrtime() - started) / 1e6
    end
    if update.done then
      result.complete_ms = (vim.uv.hrtime() - started) / 1e6
      result.count = #update.items
      result.incomplete = update.is_incomplete
      result.error = update.error
    end
  end)
  local completed = vim.wait(60000, function()
    return result.complete_ms ~= nil
  end, 1)
  if not completed or result.error ~= nil then
    handle:cancel()
  end
  assert(completed, "reference benchmark timed out")
  assert(result.error == nil, result.error and result.error.message or "reference benchmark failed")
  return result
end

for index = 1, runs do
  local result = measure()
  print(
    string.format(
      "reference run=%d first=%.3fms complete=%.3fms results=%d updates=%d incomplete=%s",
      index,
      result.first_ms,
      result.complete_ms,
      result.count,
      result.updates,
      tostring(result.incomplete)
    )
  )
end
