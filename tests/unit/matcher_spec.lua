local assert = require("tests.helpers.assertions")
local matcher = require("partial_completion.matcher")
local utf8 = require("partial_completion.utf8")

local function profile(category, case_mode, allow_subsequence, matching_style)
  return {
    category = category,
    case_mode = case_mode or "sensitive",
    allow_subsequence = allow_subsequence == true,
    matching_style = matching_style,
  }
end

return {
  {
    name = "empty query matches as a prefix without spans",
    run = function()
      local match = matcher.match("", "candidate", profile("generic"))
      assert.same("prefix", match.level)
      assert.same({}, match.spans)
    end,
  },
  {
    name = "empty query and candidate are exact",
    run = function()
      assert.same("exact", matcher.match("", "", profile("generic")).level)
    end,
  },
  {
    name = "path components cannot skip hard boundaries",
    run = function()
      assert.truthy(matcher.match("de/li", "Desktop/Library/", profile("path", "insensitive")))
      assert.falsy(matcher.match("de/li", "Desktop/Local/Library/", profile("path", "insensitive")))
    end,
  },
  {
    name = "Windows path matching treats slash and backslash as hard separators",
    run = function()
      local windows = {
        category = "path",
        profile = "path",
        case_mode = "insensitive",
        path_separator = "both",
      }
      local match = matcher.match([[de\li]], [[Desktop\Library]], windows)
      assert.truthy(match)
      assert.same("component_prefix", match.level)
      assert.truthy(matcher.match([[de/li]], [[Desktop\Library]], windows))
      assert.falsy(matcher.match([[de\li]], [[Desktop\Local\Library]], windows))

      local children = matcher.rank([[de\]], {
        { id = "long", text = [[Desktop\long-child\]] },
        { id = "short", text = [[Desktop\a\]] },
      }, windows)
      assert.same({ "short", "long" }, { children[1].id, children[2].id })

      local posix = {
        category = "path",
        profile = "path",
        case_mode = "insensitive",
        path_separator = "/",
      }
      assert.falsy(matcher.match([[de\li]], [[Desktop\Library]], posix))
    end,
  },
  {
    name = "trailing path separator expands exactly one child level",
    run = function()
      assert.truthy(matcher.match("de/", "Desktop/Library/", profile("path", "insensitive")))
      assert.truthy(matcher.match("de/", "Desktop/license.txt", profile("path", "insensitive")))
      assert.falsy(matcher.match("de/", "Desktop/Local/Library/", profile("path", "insensitive")))
    end,
  },
  {
    name = "trailing path separator ranks by character length then original text",
    run = function()
      local ranked = matcher.rank("~/d/", {
        { id = "long", text = "~/docs/long-child/" },
        { id = "lower", text = "~/dotfiles/b/" },
        { id = "upper", text = "~/Desktop/a/" },
        { id = "ascii", text = "~/d/aa/" },
        { id = "unicode", text = "~/d/é/" },
      }, profile("path", "insensitive"))
      local ids = {}
      for _, item in ipairs(ranked) do
        ids[#ids + 1] = item.id
      end
      assert.same({ "unicode", "ascii", "upper", "lower", "long" }, ids)
    end,
  },
  {
    name = "path compact initials remain disabled",
    run = function()
      assert.falsy(matcher.match("pc", "partial-completion", profile("path")))
      assert.truthy(matcher.match("pa-co", "partial-completion", profile("path")))
    end,
  },
  {
    name = "symbol initials and explicit words have distinct levels",
    run = function()
      assert.same("initials", matcher.match("tff", "TelescopeFindFiles", profile("command", "smart")).level)
      assert.same("word_prefix", matcher.match("te-fi-fi", "TelescopeFindFiles", profile("command", "smart")).level)
    end,
  },
  {
    name = "Emacs matching style keeps wildcards repeats and boundaries separate from extensions",
    run = function()
      local emacs = profile("generic", "sensitive", false, "emacs")
      assert.same("prefix", matcher.match("", "debug-list", emacs).level)
      assert.same("exact", matcher.match("debug-list", "debug-list", emacs).level)
      assert.truthy(matcher.match("de*li", "debug-list", emacs))
      assert.truthy(matcher.match("de-li", "debug-long-list", emacs))
      assert.truthy(matcher.match("de--li", "debug-long-list", emacs))
      assert.falsy(matcher.match("de--li", "debug-list", emacs))
      assert.falsy(matcher.match("de---li", "debug-longer-list", emacs))
      assert.falsy(matcher.match("tff", "TelescopeFindFiles", profile("command", "insensitive", false, "emacs")))
      assert.truthy(matcher.match("tff", "TelescopeFindFiles", profile("command", "insensitive")))
    end,
  },
  {
    name = "Emacs matching style preserves hard and explicitly typed structural path components",
    run = function()
      local emacs = profile("path", "insensitive", false, "emacs")
      assert.truthy(matcher.match("f*/ba", "fizz/barn/", emacs))
      assert.truthy(matcher.match("de//li", "Desktop/Local/Library/", emacs))
      assert.truthy(matcher.match("foo/./ba", "foo/./bar/", emacs))
      assert.truthy(matcher.match("foo/../fo/ba", "foo/../foo/bar/", emacs))
    end,
  },
  {
    name = "Emacs matching style ranks every result by character length then original text",
    run = function()
      local ranked = matcher.rank("de-li", {
        { id = "long", text = "debug-long-list" },
        { id = "describe", text = "describe-link" },
        { id = "delete", text = "delete-line" },
        { id = "debug", text = "debug-list" },
      }, profile("generic", "sensitive", false, "emacs"))
      assert.same({ "debug", "delete", "describe", "long" }, {
        ranked[1].id,
        ranked[2].id,
        ranked[3].id,
        ranked[4].id,
      })
    end,
  },
  {
    name = "subsequence is an explicit fallback",
    run = function()
      assert.falsy(matcher.match("dgls", "debug-list", profile("command")))
      assert.same("subsequence", matcher.match("dgls", "debug-list", profile("command", "sensitive", true)).level)
    end,
  },
  {
    name = "subsequence chooses the optimal repeated-character alignment",
    run = function()
      local insensitive = profile("command", "insensitive", true)
      local match = matcher.match("ab", "Aab", insensitive)
      assert.same("subsequence", match.level)
      assert.same(0, match.case_mismatches)
      assert.same({ { 1, 3 } }, match.spans)

      local ranked = matcher.rank("ab", {
        { id = "optimal", text = "Aab" },
        { id = "gapped", text = "axxb" },
      }, insensitive)
      assert.same({ "optimal", "gapped" }, { ranked[1].id, ranked[2].id })
    end,
  },
  {
    name = "custom path profiles inherit trailing-child ordering",
    run = function()
      local ranked = matcher.rank("d/", {
        { id = "long", text = "desktop/a/" },
        { id = "short", text = "D/z/" },
      }, {
        category = "custom-path",
        profile = "path",
        case_mode = "insensitive",
        path_separator = "/",
      })
      assert.same({ "short", "long" }, { ranked[1].id, ranked[2].id })
    end,
  },
  {
    name = "generic matching does not inherit CamelCase or digit boundaries",
    run = function()
      assert.falsy(matcher.match("alBe", "alphaBeta", profile("generic")))
      assert.falsy(matcher.match("ver2", "version2Value", profile("generic")))
      assert.truthy(matcher.match("alpha be", "alpha beta", profile("generic")))
    end,
  },
  {
    name = "invalid UTF-8 never produces a match",
    run = function()
      assert.falsy(matcher.match(string.char(0xFF), "candidate", profile("generic")))
      assert.falsy(matcher.match("query", string.char(0xFF), profile("generic")))
    end,
  },
  {
    name = "every highlight span is ordered and UTF-8 safe",
    run = function()
      local candidate = "ÉtudeFindFile"
      local match = matcher.match("éff", candidate, profile("command", "insensitive"))
      assert.truthy(match)
      local previous_end = 0
      for _, span in ipairs(match.spans) do
        assert.truthy(span[1] >= previous_end)
        assert.truthy(utf8.is_boundary(candidate, span[1]))
        assert.truthy(utf8.is_boundary(candidate, span[2]))
        previous_end = span[2]
      end
    end,
  },
  {
    name = "ranking is independent of input iteration order",
    run = function()
      local first = {
        { id = "three", text = "describe-link", source_order = 3 },
        { id = "one", text = "debug-list", source_order = 1 },
        { id = "two", text = "delete-line", source_order = 2 },
      }
      local second = { first[2], first[3], first[1] }
      local function ids(items)
        local result = {}
        for _, item in ipairs(items) do
          result[#result + 1] = item.id
        end
        return result
      end
      assert.same(
        ids(matcher.rank("de-li", first, profile("command", "insensitive"))),
        ids(matcher.rank("de-li", second, profile("command", "insensitive")))
      )
    end,
  },
  {
    name = "rank returns finite descending scores",
    run = function()
      local ranked = matcher.rank("debug-list", {
        { id = "word", text = "debug-long-list", source_order = 1 },
        { id = "prefix", text = "debug-list-extra", source_order = 2 },
        { id = "exact", text = "debug-list", source_order = 3 },
      }, profile("command"))
      assert.same({ "exact", "prefix", "word" }, { ranked[1].id, ranked[2].id, ranked[3].id })
      assert.truthy(ranked[1].match.score > ranked[2].match.score)
      assert.truthy(ranked[2].match.score > ranked[3].match.score)
      for _, item in ipairs(ranked) do
        assert.truthy(item.match.score == item.match.score)
        assert.truthy(item.match.score < math.huge and item.match.score > -math.huge)
      end
    end,
  },
}
