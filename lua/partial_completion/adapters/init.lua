local config = require("partial_completion.config")
local utf8 = require("partial_completion.utf8")

local M = {
  api_version = 1,
}

local host_score_step = 1024

local lsp_kind = {
  buffer = 1,
  command = 3,
  directory = 19,
  file = 17,
  ["function"] = 3,
  help = 1,
  mapping = 1,
  new_file = 17,
  option = 10,
  path = 17,
  symlink = 17,
  value = 12,
  variable = 6,
}

local function invalid(message)
  error("invalid adapter input: " .. message, 3)
end

local function integer(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge and value % 1 == 0
end

local function finite(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function valid_range(range)
  return type(range) == "table"
    and integer(range.start_byte)
    and integer(range.end_byte)
    and range.start_byte >= 0
    and range.start_byte <= range.end_byte
end

local function copy_range(range)
  return range and {
    start_byte = range.start_byte,
    end_byte = range.end_byte,
  } or nil
end

local function validate_item(item, index)
  local prefix = "items[" .. index .. "]"
  if type(item) ~= "table" then
    invalid(prefix .. " must be a table")
  end
  for _, field in ipairs({ "id", "source", "label", "insert_text", "kind" }) do
    if type(item[field]) ~= "string" or item[field] == "" then
      invalid(prefix .. "." .. field .. " must be a non-empty string")
    end
  end
  if not utf8.is_valid(item.label) or not utf8.is_valid(item.insert_text) then
    invalid(prefix .. " text must be valid UTF-8")
  end
  if type(item.match) ~= "table" or not finite(item.match.score) or type(item.match.level) ~= "string" then
    invalid(prefix .. ".match must contain a finite score and level")
  end
  if type(item.match.spans) ~= "table" then
    invalid(prefix .. ".match.spans must be a table")
  end

  local previous_end = 0
  for span_index, span in ipairs(item.match.spans) do
    if
      type(span) ~= "table"
      or not integer(span[1])
      or not integer(span[2])
      or span[1] < previous_end
      or span[1] >= span[2]
      or span[2] > #item.label
      or not utf8.is_boundary(item.label, span[1])
      or not utf8.is_boundary(item.label, span[2])
    then
      invalid(prefix .. ".match.spans[" .. span_index .. "] is invalid")
    end
    previous_end = span[2]
  end
end

function M.snapshot(update)
  if type(update) ~= "table" then
    invalid("update must be a table")
  end
  if update.api_version ~= 1 then
    invalid("update.api_version must equal 1")
  end
  if not integer(update.request_id) or not integer(update.generation) then
    invalid("update identities must be integers")
  end
  if update.replacement ~= nil and not valid_range(update.replacement) then
    invalid("update.replacement must be a valid byte range")
  end
  if type(update.items) ~= "table" then
    invalid("update.items must be a table")
  end

  local items = {}
  local seen = {}
  local previous_score = math.huge
  for index, item in ipairs(update.items) do
    validate_item(item, index)
    local key = item.source .. "\0" .. item.id
    if seen[key] then
      invalid("item identities must be unique")
    end
    if item.match.score >= previous_score then
      invalid("item scores must be strictly descending")
    end
    seen[key] = true
    previous_score = item.match.score
    items[index] = config.copy(item)
  end

  return {
    api_version = 1,
    request_id = update.request_id,
    generation = update.generation,
    replacement = copy_range(update.replacement),
    items = items,
    is_incomplete = update.is_incomplete == true,
    done = update.done == true,
    error = config.copy(update.error),
  }
end

function M.finalizer(callback)
  if type(callback) ~= "function" then
    error("adapter finalizer callback must be a function", 2)
  end
  local terminal = false
  return function(update)
    if terminal then
      return
    end
    local snapshot = M.snapshot(update)
    if snapshot.done then
      terminal = true
      callback(snapshot)
    end
  end
end

local function whitespace(byte)
  return byte == 9 or byte == 10 or byte == 13 or byte == 32
end

local function escaped(line, index)
  local count = 0
  index = index - 1
  while index >= 1 and string.byte(line, index) == 92 do
    count = count + 1
    index = index - 1
  end
  return count % 2 == 1
end

local function token_delimiter(line, index)
  local byte = string.byte(line, index)
  return (whitespace(byte) or byte == 34 or byte == 39) and not escaped(line, index)
end

local function active_quote(line, cursor_byte)
  local quote
  local quote_start
  local index = 1
  while index <= cursor_byte do
    local byte = string.byte(line, index)
    if byte == 92 and index < cursor_byte then
      index = index + 2
    else
      if quote ~= nil then
        if byte == quote then
          quote = nil
          quote_start = nil
        end
      elseif byte == 34 or byte == 39 then
        quote = byte
        quote_start = index
      end
      index = index + 1
    end
  end
  return quote, quote_start
end

local function decode_path_token(raw)
  local decoded = {}
  local style = {
    backslash = false,
    whitespace = false,
    single_quote = false,
    double_quote = false,
  }
  local index = 1
  while index <= #raw do
    local byte = string.byte(raw, index)
    local next_byte = string.byte(raw, index + 1)
    if
      byte == 92
      and next_byte ~= nil
      and (whitespace(next_byte) or next_byte == 92 or next_byte == 34 or next_byte == 39)
    then
      if next_byte == 92 then
        style.backslash = true
      elseif whitespace(next_byte) then
        style.whitespace = true
      elseif next_byte == 39 then
        style.single_quote = true
      else
        style.double_quote = true
      end
      decoded[#decoded + 1] = string.char(next_byte)
      index = index + 2
    else
      decoded[#decoded + 1] = string.sub(raw, index, index)
      index = index + 1
    end
  end
  return table.concat(decoded), style
end

local function scan_token(line, cursor_byte, options)
  options = options or {}
  if type(line) ~= "string" or not utf8.is_valid(line) or string.find(line, "[\r\n]") then
    invalid("line must be single-line valid UTF-8")
  end
  if not integer(cursor_byte) or not utf8.is_boundary(line, cursor_byte) then
    invalid("cursor_byte must be a UTF-8 byte boundary")
  end

  local quote, quote_start = active_quote(line, cursor_byte)
  local start_byte = options.start_byte
  if start_byte == nil then
    if quote_start ~= nil then
      start_byte = quote_start
    else
      start_byte = cursor_byte
      while start_byte > 0 do
        if token_delimiter(line, start_byte) then
          break
        end
        start_byte = start_byte - 1
      end
    end
  end

  local end_byte = options.end_byte
  if end_byte == nil then
    end_byte = cursor_byte
    while end_byte < #line do
      local index = end_byte + 1
      local byte = string.byte(line, index)
      local delimiter
      if quote ~= nil then
        delimiter = byte == quote and not escaped(line, index)
      else
        delimiter = token_delimiter(line, index)
      end
      if delimiter then
        break
      end
      end_byte = end_byte + 1
    end
  end

  if
    not integer(start_byte)
    or not integer(end_byte)
    or start_byte < 0
    or start_byte > cursor_byte
    or cursor_byte > end_byte
    or end_byte > #line
    or not utf8.is_boundary(line, start_byte)
    or not utf8.is_boundary(line, end_byte)
  then
    invalid("token range must contain the cursor on UTF-8 boundaries")
  end

  local raw_query = string.sub(line, start_byte + 1, cursor_byte)
  local logical_query, escape_style = decode_path_token(raw_query)
  return {
    start_byte = start_byte,
    end_byte = end_byte,
    raw_query = raw_query,
    logical_query = logical_query,
    quote = quote and string.char(quote) or nil,
    escape_style = escape_style,
  }
end

function M.token_range(line, cursor_byte, options)
  local token = scan_token(line, cursor_byte, options)
  return {
    start_byte = token.start_byte,
    end_byte = token.end_byte,
    query = token.raw_query,
  }
end

function M.encode_path_token(token, text)
  if type(token) ~= "table" or type(text) ~= "string" then
    invalid("path token and insertion text are required")
  end
  local style = token.escape_style or {}
  local encoded = {}
  for index = 1, #text do
    local byte = string.byte(text, index)
    local character = string.sub(text, index, index)
    local escape = token.quote ~= nil and character == token.quote
      or token.quote == nil and (whitespace(byte) or byte == 34 or byte == 39)
      or style.backslash and byte == 92
      or style.single_quote and byte == 39
      or style.double_quote and byte == 34
    if escape then
      encoded[#encoded + 1] = "\\"
    end
    encoded[#encoded + 1] = character
  end
  return table.concat(encoded)
end

function M.text_request(context, options)
  options = options or {}
  if type(context) ~= "table" then
    invalid("text context must be a table")
  end
  local token = scan_token(context.line, context.cursor_byte, {
    start_byte = context.start_byte,
    end_byte = context.end_byte,
  })
  local category = options.category or "path"
  local provider = options.provider or (category == "path" and "filesystem" or nil)
  local query = category == "path" and token.logical_query or token.raw_query
  return {
    api_version = 1,
    category = category,
    query = query,
    source_text = context.line,
    cursor_byte = context.cursor_byte,
    replacement = {
      start_byte = token.start_byte,
      end_byte = token.end_byte,
    },
    cwd = options.cwd,
    case_mode = options.case_mode,
    matching_style = options.matching_style,
    allow_subsequence = options.allow_subsequence == true,
    limit = options.limit,
    provider = provider,
    context = config.copy(options.context or {}),
  },
    token
end

local function filter_text(option, item)
  if type(option) == "function" then
    return option(item)
  end
  if type(option) == "string" then
    return option
  end
  return item.label
end

local function insertion_text(option, item)
  if type(option) == "function" then
    return option(item)
  end
  if type(option) == "string" then
    return option
  end
  return item.insert_text
end

function M.lsp_items(snapshot, position, options)
  options = options or {}
  snapshot = M.snapshot(snapshot)
  if
    type(position) ~= "table"
    or not integer(position.line)
    or position.line < 0
    or not integer(position.start_byte)
    or not integer(position.end_byte)
    or position.start_byte < 0
    or position.start_byte > position.end_byte
  then
    invalid("LSP position must contain a line and byte range")
  end

  local items = {}
  for index, item in ipairs(snapshot.items) do
    if string.find(item.label, "[\r\n]") or string.find(item.insert_text, "[\r\n]") then
      invalid("single-line LSP items must not contain CR or LF")
    end
    local applied_text = insertion_text(options.insert_text, item)
    if type(applied_text) ~= "string" or string.find(applied_text, "[\r\n]") then
      invalid("single-line LSP insertion text must be a string without CR or LF")
    end
    items[index] = {
      label = item.label,
      kind = options.uniform_kind and 1 or (lsp_kind[item.kind] or 1),
      detail = item.detail,
      filterText = filter_text(options.filter_text, item),
      sortText = string.format("%010d", index),
      insertTextFormat = 1,
      textEdit = {
        newText = applied_text,
        range = {
          start = { line = position.line, character = position.start_byte },
          ["end"] = { line = position.line, character = position.end_byte },
        },
      },
      data = {
        partial_completion = {
          api_version = 1,
          id = item.id,
          source = item.source,
          kind = item.kind,
          score = item.match.score,
          level = item.match.level,
          spans = config.copy(item.match.spans),
          provider_data = config.copy(item.data),
          is_incomplete = snapshot.is_incomplete,
          ordinal = index,
          request_id = snapshot.request_id,
          generation = snapshot.generation,
          source_text = options.source_text,
          cursor_byte = options.cursor_byte,
          replacement = copy_range(snapshot.replacement),
          applied_text = applied_text,
        },
      },
      score_offset = (#snapshot.items - index + 1) * host_score_step,
    }
  end
  return items
end

local function lsp_metadata(item)
  return type(item) == "table"
      and type(item.data) == "table"
      and type(item.data.partial_completion) == "table"
      and item.data.partial_completion
    or nil
end

local function same_range(left, right)
  return type(left) == "table"
    and type(right) == "table"
    and left.start_byte == right.start_byte
    and left.end_byte == right.end_byte
end

function M.same_lsp_context(item, context)
  local metadata = lsp_metadata(item)
  if metadata == nil or metadata.source_text == nil or metadata.cursor_byte == nil then
    return false
  end
  if
    type(context) ~= "table"
    or metadata.source_text ~= context.source_text
    or metadata.cursor_byte ~= context.cursor_byte
  then
    return false
  end
  if context.request_id ~= nil and metadata.request_id ~= context.request_id then
    return false
  end
  if context.generation ~= nil and metadata.generation ~= context.generation then
    return false
  end
  if context.replacement ~= nil and not same_range(metadata.replacement, context.replacement) then
    return false
  end
  return true
end

function M.applied_lsp_context(item, context)
  local metadata = lsp_metadata(item)
  if
    metadata == nil
    or type(metadata.source_text) ~= "string"
    or type(metadata.applied_text) ~= "string"
    or not valid_range(metadata.replacement)
    or metadata.replacement.end_byte > #metadata.source_text
    or type(context) ~= "table"
  then
    return false
  end
  local expected = string.sub(metadata.source_text, 1, metadata.replacement.start_byte)
    .. metadata.applied_text
    .. string.sub(metadata.source_text, metadata.replacement.end_byte + 1)
  return context.source_text == expected
    and context.cursor_byte == metadata.replacement.start_byte + #metadata.applied_text
end

return M
