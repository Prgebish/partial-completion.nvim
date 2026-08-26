local M = {}

function M.is_ascii(text)
  return type(text) == "string" and string.find(text, "[\128-\255]") == nil
end

local function sequence_length(byte)
  if byte < 0x80 then
    return 1
  end
  if byte >= 0xC2 and byte <= 0xDF then
    return 2
  end
  if byte >= 0xE0 and byte <= 0xEF then
    return 3
  end
  if byte >= 0xF0 and byte <= 0xF4 then
    return 4
  end
  return nil
end

local function continuation(byte)
  return byte ~= nil and byte >= 0x80 and byte <= 0xBF
end

local function valid_sequence(text, index, length)
  local first = string.byte(text, index)
  local second = string.byte(text, index + 1)

  if index + length - 1 > #text then
    return false
  end

  for offset = 1, length - 1 do
    if not continuation(string.byte(text, index + offset)) then
      return false
    end
  end

  if length == 3 then
    if first == 0xE0 and (second == nil or second < 0xA0) then
      return false
    end
    if first == 0xED and (second == nil or second > 0x9F) then
      return false
    end
  elseif length == 4 then
    if first == 0xF0 and (second == nil or second < 0x90) then
      return false
    end
    if first == 0xF4 and (second == nil or second > 0x8F) then
      return false
    end
  end

  return true
end

function M.chars(text)
  if type(text) ~= "string" then
    return nil, "expected string"
  end

  local result = {}
  local index = 1
  while index <= #text do
    local length = sequence_length(string.byte(text, index))
    if length == nil or not valid_sequence(text, index, length) then
      return nil, "invalid UTF-8 at byte " .. tostring(index - 1)
    end

    result[#result + 1] = {
      text = string.sub(text, index, index + length - 1),
      start_byte = index - 1,
      end_byte = index + length - 1,
    }
    index = index + length
  end

  return result
end

function M.is_valid(text)
  if M.is_ascii(text) then
    return true
  end
  return M.chars(text) ~= nil
end

function M.is_boundary(text, position)
  if type(text) ~= "string" or type(position) ~= "number" then
    return false
  end
  if position < 0 or position > #text or position % 1 ~= 0 then
    return false
  end
  if position == 0 or position == #text then
    return true
  end

  local byte = string.byte(text, position + 1)
  return byte < 0x80 or byte > 0xBF
end

function M.lower(text)
  if type(text) ~= "string" then
    return nil
  end
  if M.is_ascii(text) then
    return string.lower(text)
  end
  if not M.is_valid(text) then
    return nil
  end
  return vim.fn.tolower(text)
end

function M.upper(text)
  if type(text) ~= "string" then
    return nil
  end
  if M.is_ascii(text) then
    return string.upper(text)
  end
  if not M.is_valid(text) then
    return nil
  end
  return vim.fn.toupper(text)
end

function M.has_upper(text)
  local lower = M.lower(text)
  return lower ~= nil and lower ~= text
end

function M.coalesce_spans(spans)
  local result = {}
  for _, span in ipairs(spans) do
    local previous = result[#result]
    if previous ~= nil and previous[2] == span[1] then
      previous[2] = span[2]
    else
      result[#result + 1] = { span[1], span[2] }
    end
  end
  return result
end

return M
