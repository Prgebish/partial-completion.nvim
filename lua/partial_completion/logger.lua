local config = require("partial_completion.config")

local M = {}

local options = {
  enabled = false,
  sensitive = false,
  max_entries = 200,
  sink = nil,
}
local records = {}
local sequence = 0

local sensitive_fields = {
  cwd = true,
  home = true,
  insert_text = true,
  label = true,
  message = true,
  original = true,
  path = true,
  query = true,
  root = true,
  scan_root = true,
  source_text = true,
  target = true,
}

local function redacted(value)
  if type(value) == "string" then
    return string.format("<redacted:%d-bytes>", #value)
  end
  return "<redacted>"
end

local function sanitize(value, key, seen)
  if sensitive_fields[key] and not options.sensitive then
    return redacted(value)
  end
  if type(value) ~= "table" then
    if type(value) == "function" or type(value) == "userdata" or type(value) == "thread" then
      return "<" .. type(value) .. ">"
    end
    return value
  end
  seen = seen or {}
  if seen[value] then
    return "<cycle>"
  end
  seen[value] = true
  local result = {}
  for child_key, child in pairs(value) do
    local key_type = type(child_key)
    local safe_key = (key_type == "string" or key_type == "number") and child_key or tostring(child_key)
    result[safe_key] = sanitize(child, type(child_key) == "string" and child_key or nil, seen)
  end
  seen[value] = nil
  return result
end

local function append(record)
  records[#records + 1] = record
  while #records > options.max_entries do
    table.remove(records, 1)
  end
end

function M.configure(new_options)
  local previous_sensitive = options.sensitive == true
  options = config.copy(new_options or options)
  if not options.enabled then
    records = {}
    return
  end
  if previous_sensitive and not options.sensitive then
    records = {}
  end
  while #records > options.max_entries do
    table.remove(records, 1)
  end
end

function M.emit(level, event, fields)
  if not options.enabled then
    return
  end
  sequence = sequence + 1
  local record = {
    sequence = sequence,
    level = level,
    event = event,
    fields = sanitize(fields or {}),
  }
  append(record)
  if type(options.sink) == "function" then
    local ok, err = pcall(options.sink, config.copy(record))
    if not ok then
      sequence = sequence + 1
      append({
        sequence = sequence,
        level = "error",
        event = "debug_sink_failed",
        fields = { message = redacted(tostring(err)) },
      })
    end
  end
end

function M.debug(event, fields)
  M.emit("debug", event, fields)
end

function M.records()
  return config.copy(records)
end

function M.clear()
  records = {}
end

function M.enabled()
  return options.enabled == true
end

return M
