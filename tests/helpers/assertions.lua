local M = {}

local function inspect(value)
  return vim.inspect(value)
end

function M.same(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error((message or "values differ") .. "\nexpected: " .. inspect(expected) .. "\nactual:   " .. inspect(actual), 2)
  end
end

function M.truthy(value, message)
  if not value then
    error(message or "expected truthy value", 2)
  end
end

function M.falsy(value, message)
  if value then
    error(message or "expected falsy value", 2)
  end
end

function M.raises(pattern, callback)
  local ok, err = pcall(callback)
  if ok then
    error("expected callback to raise", 2)
  end
  if pattern ~= nil and not string.find(tostring(err), pattern) then
    error("error did not match " .. pattern .. ": " .. tostring(err), 2)
  end
end

return M
