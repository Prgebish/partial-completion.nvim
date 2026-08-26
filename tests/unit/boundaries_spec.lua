local assert = require("tests.helpers.assertions")
local boundaries = require("partial_completion.boundaries")

local function compact(words)
  local result = {}
  for _, word in ipairs(words) do
    result[#result + 1] = { word.text, word.start_byte, word.end_byte }
  end
  return result
end

return {
  {
    name = "all frozen categories resolve to profiles",
    run = function()
      for category, _ in pairs(boundaries.categories) do
        assert.truthy(boundaries.profile_for(category, "query", "candidate"))
      end
      assert.same("generic", boundaries.profile_for("custom-category", "q", "candidate"))
      assert.same("insensitive", boundaries.default_case_mode("path"))
      assert.same("smart", boundaries.default_case_mode("command"))
    end,
  },
  {
    name = "symbol boundaries cover punctuation and CamelCase",
    run = function()
      local words, explicit = boundaries.words("alpha-beta_Gamma.delta", "symbol")
      assert.truthy(explicit)
      assert.same({
        { "alpha", 0, 5 },
        { "beta", 6, 10 },
        { "Gamma", 11, 16 },
        { "delta", 17, 22 },
      }, compact(words))
    end,
  },
  {
    name = "symbol boundaries split acronyms and digits",
    run = function()
      local words = boundaries.words("HTTPServer2Value", "symbol")
      assert.same({
        { "HTTP", 0, 4 },
        { "Server", 4, 10 },
        { "2", 10, 11 },
        { "Value", 11, 16 },
      }, compact(words))
    end,
  },
  {
    name = "generic boundaries split whitespace only",
    run = function()
      local words, explicit = boundaries.words("alpha-beta Gamma", "generic")
      assert.truthy(explicit)
      assert.same({
        { "alpha-beta", 0, 10 },
        { "Gamma", 11, 16 },
      }, compact(words))
    end,
  },
  {
    name = "Unicode case participates in CamelCase boundaries",
    run = function()
      local words = boundaries.words("éValueName", "symbol")
      assert.same({
        { "é", 0, 2 },
        { "Value", 2, 7 },
        { "Name", 7, 11 },
      }, compact(words))
    end,
  },
  {
    name = "path components preserve empty roots and suffixes",
    run = function()
      assert.same({
        { start_byte = 0, end_byte = 0, text = "" },
        { start_byte = 1, end_byte = 4, text = "usr" },
        { start_byte = 5, end_byte = 5, text = "" },
      }, boundaries.components("/usr/"))
    end,
  },
}
