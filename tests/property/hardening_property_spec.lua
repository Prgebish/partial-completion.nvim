local assert = require("tests.helpers.assertions")
local cmdline = require("partial_completion.cmdline")
local config = require("partial_completion.config")
local Engine = require("partial_completion.engine")
local matcher = require("partial_completion.matcher")
local Providers = require("partial_completion.providers")
local utf8 = require("partial_completion.utf8")

local function profile()
  return {
    category = "generic",
    profile = "generic",
    case_mode = "sensitive",
  }
end

return {
  {
    name = "malformed UTF-8 corpus is rejected without partial spans",
    run = function()
      local corpus = {
        string.char(0x80),
        string.char(0xC0, 0xAF),
        string.char(0xE0, 0x80, 0xAF),
        string.char(0xED, 0xA0, 0x80),
        string.char(0xF0, 0x80, 0x80, 0xAF),
        string.char(0xF4, 0x90, 0x80, 0x80),
        string.char(0xE2, 0x82),
      }
      for _, malformed in ipairs(corpus) do
        assert.falsy(utf8.is_valid(malformed))
        assert.same({}, matcher.rank(malformed, { "candidate" }, profile()))
        assert.same({}, matcher.rank("candidate", { malformed }, profile()))
        assert.falsy(matcher.match(malformed, "candidate", profile()))
      end
    end,
  },
  {
    name = "filename escaping round-trips a deterministic special-byte corpus",
    run = function()
      local alphabet = { "a", "Z", "0", " ", "'", "|", "[", "]", "$", "\\", "-", "_" }
      local state = 173
      for iteration = 1, 200 do
        local value = { "f" }
        for _ = 1, 24 do
          state = (state * 48271) % 2147483647
          value[#value + 1] = alphabet[(state % #alphabet) + 1]
        end
        local original = table.concat(value)
        local encoded = cmdline.encode(original, { category = "path", completion_type = "file" })
        local source = "edit " .. encoded
        local analyzed = cmdline.analyze(source, #source, {
          live = false,
          completion_type = "file",
          completion_pattern = encoded,
        })
        assert.same(original, analyzed.query, "round-trip iteration " .. iteration)
      end
    end,
  },
  {
    name = "very long inputs remain bounded and byte-correct",
    run = function()
      local query = string.rep("a", 32768)
      local candidate = query .. "b"
      local started = vim.uv.hrtime()
      local match = matcher.match(query, candidate, profile())
      local elapsed_ms = (vim.uv.hrtime() - started) / 1000000
      assert.truthy(match)
      assert.same("prefix", match.level)
      assert.same({ { 0, #query } }, match.spans)
      assert.truthy(elapsed_ms < 2000, string.format("long prefix took %.3f ms", elapsed_ms))
    end,
  },
  {
    name = "malformed provider items and error values terminate safely",
    run = function()
      local providers = Providers.new()
      providers:register("hardening-errors", {
        api_version = 1,
        categories = { "generic" },
        complete = function(_, emit, done)
          emit({
            false,
            {},
            { id = "bad-label", label = string.char(0xFF), insert_text = "x" },
            { id = "bad-order", label = "x", insert_text = "x", source_order = 0 / 0 },
            { id = "valid", label = "valid", insert_text = "valid", source_order = 1 },
          })
          done({ code = "fuzzed_provider", message = {}, transient = true })
          return { cancel = function() end }
        end,
      })
      local engine = Engine.new(config.resolve({}), providers)
      local final
      engine:complete({ category = "generic", query = "v", provider = "hardening-errors" }, function(update)
        final = update
      end)
      assert.truthy(final.done)
      assert.truthy(final.is_incomplete)
      assert.same({ "valid" }, { final.items[1].id })
      assert.same("fuzzed_provider", final.error.code)
      assert.truthy(final.error.transient)
    end,
  },
}
