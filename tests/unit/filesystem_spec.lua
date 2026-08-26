local assert = require("tests.helpers.assertions")
local filesystem = require("partial_completion.providers.filesystem")

local contract_cases = dofile("tests/contract/cases.lua").paths

return {
  {
    name = "filesystem roots satisfy the frozen path contract",
    run = function()
      for _, case in ipairs(contract_cases) do
        assert.same(case.expected, filesystem.parse_root(case.input, case.context), case.id)
      end
    end,
  },
  {
    name = "root-only forms and repeated parents retain insertion spelling",
    run = function()
      local context = { cwd = "/work/project/src", home = "/home/alice", env = {}, platform = "posix" }
      assert.same({
        status = "ok",
        root_kind = "home",
        root_text = "~",
        scan_root = "/home/alice",
        remainder = "",
      }, filesystem.parse_root("~", context))
      assert.same({
        status = "ok",
        root_kind = "parent",
        root_text = "../../",
        scan_root = "/work",
        remainder = "notes",
      }, filesystem.parse_root("../../notes", context))
    end,
  },
  {
    name = "environment expansion is single-pass and malformed names stay literal",
    run = function()
      local context = {
        cwd = "/work/project",
        home = "/home/alice",
        env = { ROOT = "$OTHER", OTHER = "/expanded" },
        platform = "posix",
      }
      assert.same({
        status = "ok",
        root_kind = "environment",
        root_text = "$ROOT/",
        scan_root = "/work/project/$OTHER",
        remainder = "src",
      }, filesystem.parse_root("$ROOT/src", context))
      assert.same("relative", filesystem.parse_root("$1/literal", context).root_kind)
    end,
  },
  {
    name = "Windows roots separators environment values and reserved names are explicit",
    run = function()
      local context = {
        cwd = [[C:\work\project\src]],
        home = [[C:\Users\alice]],
        env = { ROOT = [[D:\vendor]] },
        platform = "windows",
      }
      assert.same({
        status = "ok",
        root_kind = "environment",
        root_text = [[$ROOT\]],
        scan_root = "D:/vendor",
        remainder = [[src\mo]],
      }, filesystem.parse_root([[$ROOT\src\mo]], context))
      assert.same({
        status = "ok",
        root_kind = "parent",
        root_text = [[..\..\]],
        scan_root = "C:/work",
        remainder = "notes",
      }, filesystem.parse_root([[..\..\notes]], context))
      assert.same({
        status = "ok",
        root_kind = "absolute",
        root_text = [[\]],
        scan_root = "C:/",
        remainder = [[Windows\Sys]],
      }, filesystem.parse_root([[\Windows\Sys]], context))

      local path = require("partial_completion.path")
      assert.same("C:/Windows/System32", path.resolve([[\Windows\System32]], [[C:\work\project]], "windows"))
      assert.same("//server/share/logs", path.resolve([[\logs]], [[\\server\share\work\project]], "windows"))

      for _, name in ipairs({ "CON", "con.txt", "PRN", "AUX.log", "NUL", "COM1", "LPT9.md", "COM¹", "LPT².txt" }) do
        assert.truthy(filesystem.is_windows_reserved_name(name), name)
        assert.falsy(filesystem.valid_windows_entry(name), name)
      end
      for _, name in ipairs({ "config", "COM10", "LPT0", "auxiliary.txt" }) do
        assert.falsy(filesystem.is_windows_reserved_name(name), name)
        assert.truthy(filesystem.valid_windows_entry(name), name)
      end
      for _, name in ipairs({ "trailing.", "trailing ", "bad:name", "bad?name" }) do
        assert.falsy(filesystem.valid_windows_entry(name), name)
      end
    end,
  },
}
