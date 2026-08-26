local root = vim.uv.cwd() or vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local filesystem = require("partial_completion.providers.filesystem")
local matcher = require("partial_completion.matcher")

local function same(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error(
      (message or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual)
    )
  end
end

local windows_context = {
  cwd = [[C:\work\project]],
  home = [[C:\Users\alice]],
  env = {},
  platform = "windows",
}
same({
  status = "ok",
  root_kind = "drive",
  root_text = [[C:\]],
  scan_root = "C:/",
  remainder = [[Users\alice\de\li]],
}, filesystem.parse_root([[C:\Users\alice\de\li]], windows_context), "Windows drive parsing")
same({
  status = "ok",
  root_kind = "unc",
  root_text = [[\\server\share\]],
  scan_root = "//server/share",
  remainder = [[de\li]],
}, filesystem.parse_root([[\\server\share\de\li]], windows_context), "Windows UNC parsing")

local profile = {
  category = "path",
  profile = "path",
  case_mode = "insensitive",
  path_separator = "both",
}
assert(matcher.match([[de\li]], [[Desktop\Library]], profile), "backslash path did not match")
assert(matcher.match([[de/li]], [[Desktop\Library]], profile), "mixed-separator path did not match")
assert(filesystem.is_windows_reserved_name("CON.txt"), "reserved Windows name was not recognized")
assert(not filesystem.valid_windows_entry("bad:name"), "invalid Windows entry was accepted")

if package.config:sub(1, 1) == "\\" then
  local completion = require("partial_completion")
  local fixture = vim.fn.tempname()
  vim.fn.mkdir(fixture .. "/Desktop/Library", "p")
  vim.fn.mkdir(fixture .. "/Developer/lib", "p")
  completion.setup({ filesystem = { cache = { ttl_ms = 0 } } })

  local function complete(query, case_mode)
    local result = { items = {}, done = false, fast = false }
    local handle = completion.complete({
      category = "path",
      query = query,
      cwd = fixture,
      case_mode = case_mode or "insensitive",
      limit = 20,
    }, function(update)
      result.fast = result.fast or vim.in_fast_event()
      result.items = update.items
      result.error = update.error
      result.done = update.done
    end)
    assert(
      vim.wait(5000, function()
        return result.done
      end, 1),
      "native Windows filesystem completion timed out"
    )
    handle:cancel()
    assert(not result.fast, "native Windows callback escaped from the main loop")
    assert(result.error == nil, vim.inspect(result.error))
    local labels = {}
    for _, item in ipairs(result.items) do
      labels[#labels + 1] = item.label
    end
    table.sort(labels)
    return labels
  end

  same({ [[Desktop\Library\]], [[Developer\lib\]] }, complete([[de\li]]), "native backslash traversal")
  same({ "Desktop/Library/", "Developer/lib/" }, complete("de/li"), "native slash traversal")
  same({}, complete([[de\li]], "sensitive"), "native sensitive case policy")
  same({ [[Desktop\Library\]], [[Developer\lib\]] }, complete([[de\li]], "filesystem"), "native filesystem case policy")
  vim.fn.delete(fixture, "rf")
end

io.stdout:write("Portability verification passed on " .. vim.uv.os_uname().sysname .. "\n")
