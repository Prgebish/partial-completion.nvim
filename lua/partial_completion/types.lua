local config = require("partial_completion.config")
local path = require("partial_completion.path")
local utf8 = require("partial_completion.utf8")

local M = {}

local case_modes = {
  filesystem = true,
  smart = true,
  sensitive = true,
  insensitive = true,
}

local function invalid(message)
  error("invalid completion request: " .. message, 3)
end

local function integer(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge and value % 1 == 0
end

function M.validate_request(request, defaults)
  if type(request) ~= "table" then
    invalid("expected table")
  end
  if request.api_version ~= nil and request.api_version ~= 1 then
    invalid("api_version must equal 1")
  end
  if request.request_id ~= nil or request.generation ~= nil then
    invalid("request_id and generation are engine-owned")
  end
  if type(request.category) ~= "string" or request.category == "" then
    invalid("category must be a non-empty string")
  end
  if type(request.query) ~= "string" or not utf8.is_valid(request.query) then
    invalid("query must be valid UTF-8")
  end

  local has_source = request.source_text ~= nil
  local has_cursor = request.cursor_byte ~= nil
  local has_replacement = request.replacement ~= nil
  if has_source ~= has_cursor or has_source ~= has_replacement then
    invalid("source_text, cursor_byte, and replacement must be supplied together")
  end
  if has_source then
    if type(request.source_text) ~= "string" or not utf8.is_valid(request.source_text) then
      invalid("source_text must be valid UTF-8")
    end
    if not integer(request.cursor_byte) or not utf8.is_boundary(request.source_text, request.cursor_byte) then
      invalid("cursor_byte must be a UTF-8 byte boundary")
    end
    if
      type(request.replacement) ~= "table"
      or not integer(request.replacement.start_byte)
      or not integer(request.replacement.end_byte)
      or request.replacement.start_byte > request.replacement.end_byte
      or not utf8.is_boundary(request.source_text, request.replacement.start_byte)
      or not utf8.is_boundary(request.source_text, request.replacement.end_byte)
    then
      invalid("replacement must contain valid UTF-8 byte boundaries")
    end
  end

  local request_platform = type(request.context) == "table" and request.context.platform or nil
  if request.cwd ~= nil and (type(request.cwd) ~= "string" or not path.is_absolute(request.cwd, request_platform)) then
    invalid("cwd must be an absolute path for the request platform")
  end
  if request.case_mode ~= nil and not case_modes[request.case_mode] then
    invalid("unknown case_mode")
  end
  if request.matching_style ~= nil and request.matching_style ~= "extended" and request.matching_style ~= "emacs" then
    invalid("unknown matching_style")
  end
  if request.allow_subsequence ~= nil and type(request.allow_subsequence) ~= "boolean" then
    invalid("allow_subsequence must be boolean")
  end
  if request.limit ~= nil and (not integer(request.limit) or request.limit < 1) then
    invalid("limit must be a positive integer")
  end
  if request.provider ~= nil and (type(request.provider) ~= "string" or request.provider == "") then
    invalid("provider must be a non-empty string")
  end
  if request.context ~= nil and type(request.context) ~= "table" then
    invalid("context must be a table")
  end

  local normalized = {
    api_version = 1,
    category = request.category,
    query = request.query,
    source_text = request.source_text,
    cursor_byte = request.cursor_byte,
    replacement = config.copy(request.replacement),
    cwd = request.cwd,
    case_mode = request.case_mode,
    matching_style = request.matching_style,
    allow_subsequence = request.allow_subsequence == true,
    limit = math.min(request.limit or defaults.limit, defaults.max_limit),
    provider = request.provider,
    context = config.copy(request.context or {}),
  }
  return normalized
end

function M.normalize_item(item, source, fallback_order)
  if type(item) ~= "table" then
    return nil, "provider item must be a table"
  end
  if type(item.id) ~= "string" or item.id == "" then
    return nil, "provider item id must be a non-empty string"
  end
  if type(item.label) ~= "string" or item.label == "" or not utf8.is_valid(item.label) then
    return nil, "provider item label must be non-empty valid UTF-8"
  end
  if type(item.insert_text) ~= "string" or item.insert_text == "" or not utf8.is_valid(item.insert_text) then
    return nil, "provider item insert_text must be non-empty valid UTF-8"
  end

  local source_order = item.source_order
  if source_order ~= nil and not integer(source_order) then
    return nil, "provider item source_order must be a finite integer"
  end
  local case_mode = item._case_mode or item.case_mode
  if case_mode ~= "sensitive" and case_mode ~= "insensitive" then
    case_mode = nil
  end

  if item.data ~= nil and type(item.data) ~= "table" then
    return nil, "provider item data must be a table"
  end
  local ok, data = pcall(config.copy, item.data or {}, 64)
  if not ok then
    return nil, "provider item data must be an acyclic bounded table: " .. tostring(data)
  end

  return {
    id = item.id,
    label = item.label,
    insert_text = item.insert_text,
    kind = type(item.kind) == "string" and item.kind ~= "" and item.kind or "value",
    detail = type(item.detail) == "string" and item.detail or nil,
    source = source,
    source_order = source_order or fallback_order,
    data = data,
    _case_mode = case_mode,
  }
end

function M.error(code, message, transient)
  return {
    code = code,
    message = message,
    transient = transient == true,
  }
end

return M
