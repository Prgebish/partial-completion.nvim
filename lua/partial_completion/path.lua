local M = {}

local function native_platform()
  return package.config:sub(1, 1) == "\\" and "windows" or "posix"
end

function M.platform(value)
  return value == "windows" and "windows" or value == "posix" and "posix" or native_platform()
end

function M.is_separator(character, platform)
  return character == "/" or (platform == "windows" and character == "\\")
end

function M.separator(input, platform)
  if platform ~= "windows" then
    return "/"
  end
  local separator = "\\"
  for index = 1, #input do
    local character = string.sub(input, index, index)
    if character == "/" or character == "\\" then
      separator = character
    end
  end
  return separator
end

local function normalized_parts(input, offset, initial)
  local parts = initial or {}
  for part in string.gmatch(string.sub(input, offset or 1), "[^/]+") do
    if part == ".." then
      if #parts > 0 then
        parts[#parts] = nil
      end
    elseif part ~= "." and part ~= "" then
      parts[#parts + 1] = part
    end
  end
  return parts
end

function M.normalize_absolute(input, platform)
  platform = M.platform(platform)
  if platform == "posix" then
    return "/" .. table.concat(normalized_parts(input), "/")
  end

  local path = string.gsub(input, "\\", "/")
  if string.sub(path, 1, 8) == "//?/UNC/" then
    path = "//" .. string.sub(path, 9)
  elseif string.sub(path, 1, 4) == "//?/" then
    path = string.sub(path, 5)
  end
  local drive = string.match(path, "^([A-Za-z]):/")
  if drive ~= nil then
    local parts = normalized_parts(path, 4)
    local root = string.upper(drive) .. ":/"
    return #parts == 0 and root or root .. table.concat(parts, "/")
  end

  local server, share, remainder = string.match(path, "^//([^/]+)/([^/]+)/*(.*)$")
  if server ~= nil then
    local root = "//" .. server .. "/" .. share
    local parts = normalized_parts(remainder)
    return #parts == 0 and root or root .. "/" .. table.concat(parts, "/")
  end
  return nil
end

function M.is_absolute(input, platform)
  if type(input) ~= "string" or input == "" then
    return false
  end
  platform = M.platform(platform)
  if platform == "posix" then
    return string.sub(input, 1, 1) == "/"
  end
  return string.match(input, "^[A-Za-z]:[\\/]") ~= nil or string.match(input, "^[\\/][\\/][^\\/]+[\\/][^\\/]+") ~= nil
end

local function volume_root(cwd)
  local drive = string.match(cwd, "^([A-Za-z]):/")
  if drive ~= nil then
    return string.upper(drive) .. ":/"
  end
  local server, share = string.match(cwd, "^//([^/]+)/([^/]+)")
  if server ~= nil then
    return "//" .. server .. "/" .. share
  end
  return nil
end

function M.resolve(input, cwd, platform)
  platform = M.platform(platform)
  if platform == "posix" then
    if string.sub(input, 1, 1) == "/" then
      return M.normalize_absolute(input, platform)
    end
    return M.normalize_absolute(cwd .. "/" .. input, platform)
  end

  local normalized_cwd = M.normalize_absolute(cwd, platform)
  if normalized_cwd == nil then
    return nil
  end
  local path = string.gsub(input, "\\", "/")
  if M.is_absolute(path, platform) then
    return M.normalize_absolute(path, platform)
  end
  if string.match(path, "^[A-Za-z]:") then
    return nil
  end
  if string.sub(path, 1, 1) == "/" then
    local root = volume_root(normalized_cwd)
    return root and M.normalize_absolute(root .. path, platform) or nil
  end
  return M.normalize_absolute(normalized_cwd .. "/" .. path, platform)
end

function M.join(parent, name)
  if string.sub(parent, -1) == "/" then
    return parent .. name
  end
  return parent .. "/" .. name
end

function M.dirname(input, platform)
  local parent = string.match(input, "^(.*)/[^/]*$")
  if parent == nil or parent == "" then
    return platform == "windows" and volume_root(input) or "/"
  end
  if string.match(parent, "^[A-Za-z]:$") then
    return parent .. "/"
  end
  local root = platform == "windows" and volume_root(input) or "/"
  if root ~= nil and #parent < #root then
    return root
  end
  return parent
end

function M.is_windows_reserved_name(name)
  if type(name) ~= "string" then
    return false
  end
  local trimmed = string.gsub(name, "[ .]+$", "")
  local stem = string.upper(string.match(trimmed, "^([^.]*)") or trimmed)
  stem = string.gsub(stem, "\194\185", "1")
  stem = string.gsub(stem, "\194\178", "2")
  stem = string.gsub(stem, "\194\179", "3")
  return stem == "CON"
    or stem == "PRN"
    or stem == "AUX"
    or stem == "NUL"
    or stem == "CONIN$"
    or stem == "CONOUT$"
    or string.match(stem, "^COM[1-9]$") ~= nil
    or string.match(stem, "^LPT[1-9]$") ~= nil
end

function M.valid_windows_entry(name)
  if type(name) ~= "string" or name == "" or name == "." or name == ".." then
    return false
  end
  if M.is_windows_reserved_name(name) or string.match(name, "[ .]$") then
    return false
  end
  for index = 1, #name do
    local byte = string.byte(name, index)
    local character = string.sub(name, index, index)
    if byte < 32 or string.find('<>:"/\\|?*', character, 1, true) then
      return false
    end
  end
  return true
end

return M
