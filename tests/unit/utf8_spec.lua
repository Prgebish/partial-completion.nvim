local assert = require("tests.helpers.assertions")
local utf8 = require("partial_completion.utf8")

return {
  {
    name = "utf8 exposes zero-based byte ranges",
    run = function()
      local characters = utf8.chars("aé界")
      assert.same({
        { text = "a", start_byte = 0, end_byte = 1 },
        { text = "é", start_byte = 1, end_byte = 3 },
        { text = "界", start_byte = 3, end_byte = 6 },
      }, characters)
    end,
  },
  {
    name = "utf8 rejects overlong, surrogate, and truncated sequences",
    run = function()
      assert.falsy(utf8.is_valid(string.char(0xC0, 0x80)))
      assert.falsy(utf8.is_valid(string.char(0xED, 0xA0, 0x80)))
      assert.falsy(utf8.is_valid(string.char(0xF0, 0x9F)))
    end,
  },
  {
    name = "utf8 boundaries never split code points",
    run = function()
      local text = "aé界"
      assert.truthy(utf8.is_boundary(text, 0))
      assert.truthy(utf8.is_boundary(text, 1))
      assert.falsy(utf8.is_boundary(text, 2))
      assert.truthy(utf8.is_boundary(text, 3))
      assert.falsy(utf8.is_boundary(text, 4))
      assert.falsy(utf8.is_boundary(text, 5))
      assert.truthy(utf8.is_boundary(text, 6))
    end,
  },
  {
    name = "unicode lowercase follows Neovim",
    run = function()
      assert.same("école", utf8.lower("ÉCOLE"))
      assert.truthy(utf8.has_upper("École"))
      assert.falsy(utf8.has_upper("école"))
    end,
  },
}
