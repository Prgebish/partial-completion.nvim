local utf8 = require("partial_completion.utf8")

local M = {}

M.categories = {
  path = { profile = "path", case_mode = "insensitive" },
  command = { profile = "symbol", case_mode = "smart" },
  option = { profile = "symbol", case_mode = "smart" },
  buffer = { profile = "buffer", case_mode = "smart" },
  help = { profile = "symbol", case_mode = "smart" },
  ["function"] = { profile = "symbol", case_mode = "smart" },
  variable = { profile = "symbol", case_mode = "smart" },
  mapping = { profile = "symbol", case_mode = "smart" },
  generic = { profile = "generic", case_mode = "smart" },
}

local symbol_separators = {
  ["-"] = true,
  ["_"] = true,
  ["."] = true,
  [":"] = true,
  ["/"] = true,
  ["#"] = true,
  ["<"] = true,
  [">"] = true,
}

local path_separators = {
  ["-"] = true,
  ["_"] = true,
  ["."] = true,
}

local function ascii_whitespace(character)
  return character == " "
    or character == "\t"
    or character == "\n"
    or character == "\r"
    or character == "\f"
    or character == "\v"
end

local function classification(character)
  local byte = string.byte(character)
  if #character > 1 or byte >= 0x80 then
    local lower = utf8.lower(character)
    local upper = utf8.upper(character)
    if lower ~= character and upper == character then
      return "upper"
    end
    if upper ~= character and lower == character then
      return "lower"
    end
    return "letter"
  end
  if byte >= string.byte("a") and byte <= string.byte("z") then
    return "lower"
  end
  if byte >= string.byte("A") and byte <= string.byte("Z") then
    return "upper"
  end
  if byte >= string.byte("0") and byte <= string.byte("9") then
    return "digit"
  end
  return "other"
end

local function is_letter(kind)
  return kind == "lower" or kind == "upper" or kind == "letter"
end

local function separator_for(profile, character)
  if ascii_whitespace(character) then
    return true
  end
  if profile == "symbol" then
    return symbol_separators[character] == true
  end
  if profile == "path" then
    return path_separators[character] == true
  end
  return false
end

local symbol_separator_bytes = {
  [string.byte("-")] = true,
  [string.byte("_")] = true,
  [string.byte(".")] = true,
  [string.byte(":")] = true,
  [string.byte("/")] = true,
  [string.byte("#")] = true,
  [string.byte("<")] = true,
  [string.byte(">")] = true,
}

local path_separator_bytes = {
  [string.byte("-")] = true,
  [string.byte("_")] = true,
  [string.byte(".")] = true,
}

local function ascii_separator(profile, byte)
  if byte == 0x20 or (byte >= 0x09 and byte <= 0x0D) then
    return true
  end
  if profile == "symbol" then
    return symbol_separator_bytes[byte] == true
  end
  if profile == "path" then
    return path_separator_bytes[byte] == true
  end
  return false
end

local function ascii_kind(byte)
  if byte >= 0x61 and byte <= 0x7A then
    return "lower"
  end
  if byte >= 0x41 and byte <= 0x5A then
    return "upper"
  end
  if byte >= 0x30 and byte <= 0x39 then
    return "digit"
  end
  return "other"
end

local function ascii_letter(kind)
  return kind == "lower" or kind == "upper"
end

local function ascii_transition(previous, current, following)
  local previous_kind = ascii_kind(previous)
  local current_kind = ascii_kind(current)
  local following_kind = following and ascii_kind(following) or nil
  return (previous_kind == "lower" and current_kind == "upper")
    or (ascii_letter(previous_kind) and current_kind == "digit")
    or (previous_kind == "digit" and ascii_letter(current_kind))
    or (previous_kind == "upper" and current_kind == "upper" and following_kind == "lower")
end

local function ascii_words(text, profile)
  local words = {}
  local current_start
  local explicit_separator = false

  local function finish(end_byte)
    if current_start ~= nil then
      words[#words + 1] = {
        start_byte = current_start,
        end_byte = end_byte,
        text = string.sub(text, current_start + 1, end_byte),
      }
      current_start = nil
    end
  end

  for index = 1, #text do
    local byte = string.byte(text, index)
    if ascii_separator(profile, byte) then
      explicit_separator = true
      finish(index - 1)
    else
      local previous = index > 1 and string.byte(text, index - 1) or nil
      local following = index < #text and string.byte(text, index + 1) or nil
      if current_start == nil then
        current_start = index - 1
      elseif profile ~= "generic" and previous ~= nil and ascii_transition(previous, byte, following) then
        finish(index - 1)
        current_start = index - 1
      end
    end
  end
  finish(#text)
  return words, explicit_separator
end

local function transition(previous, current, following)
  local previous_kind = classification(previous.text)
  local current_kind = classification(current.text)
  local following_kind = following and classification(following.text) or nil

  if previous_kind == "lower" and current_kind == "upper" then
    return true
  end
  if
    (is_letter(previous_kind) and current_kind == "digit") or (previous_kind == "digit" and is_letter(current_kind))
  then
    return true
  end
  if previous_kind == "upper" and current_kind == "upper" and following_kind == "lower" then
    return true
  end
  return false
end

function M.profile_for(category, query, candidate, separator_mode)
  local category_config = M.categories[category] or M.categories.generic
  if category_config.profile ~= "buffer" then
    return category_config.profile
  end
  local query_is_path = string.find(query, "/", 1, true)
    or (separator_mode == "both" and string.find(query, "\\", 1, true))
  local candidate_is_path = string.find(candidate, "/", 1, true)
    or (separator_mode == "both" and string.find(candidate, "\\", 1, true))
  if query_is_path and candidate_is_path then
    return "path"
  end
  return "symbol"
end

function M.default_case_mode(category)
  return (M.categories[category] or M.categories.generic).case_mode
end

function M.words(text, profile, known_ascii)
  if known_ascii or utf8.is_ascii(text) then
    return ascii_words(text, profile)
  end
  local characters, err = utf8.chars(text)
  if characters == nil then
    return nil, err
  end

  local words = {}
  local current_start
  local explicit_separator = false

  local function finish(end_byte)
    if current_start == nil then
      return
    end
    words[#words + 1] = {
      start_byte = current_start,
      end_byte = end_byte,
      text = string.sub(text, current_start + 1, end_byte),
    }
    current_start = nil
  end

  for index, character in ipairs(characters) do
    if separator_for(profile, character.text) then
      explicit_separator = true
      finish(character.start_byte)
    else
      local previous = characters[index - 1]
      local following = characters[index + 1]
      if current_start == nil then
        current_start = character.start_byte
      elseif profile ~= "generic" and previous ~= nil and transition(previous, character, following) then
        finish(character.start_byte)
        current_start = character.start_byte
      end
    end
  end
  finish(#text)

  return words, explicit_separator
end

function M.components(text, separator_mode)
  if not utf8.is_valid(text) then
    return nil, "invalid UTF-8"
  end

  local components = {}
  local start_byte = 0
  while true do
    local slash = string.find(text, "/", start_byte + 1, true)
    local backslash = separator_mode == "both" and string.find(text, "\\", start_byte + 1, true) or nil
    local separator = slash
    if backslash ~= nil and (separator == nil or backslash < separator) then
      separator = backslash
    end
    local end_byte = separator and separator - 1 or #text
    components[#components + 1] = {
      start_byte = start_byte,
      end_byte = end_byte,
      text = string.sub(text, start_byte + 1, end_byte),
    }
    if separator == nil then
      break
    end
    start_byte = separator
  end

  return components
end

return M
