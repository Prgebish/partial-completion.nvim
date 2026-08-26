local assert = require("tests.helpers.assertions")
local matcher = require("partial_completion.matcher")
local utf8 = require("partial_completion.utf8")

local function shuffled(items)
  local result = {}
  for index, item in ipairs(items) do
    result[index] = item
  end
  for index = #result, 2, -1 do
    local swap = math.random(index)
    result[index], result[swap] = result[swap], result[index]
  end
  return result
end

local function ids(items)
  local result = {}
  for _, item in ipairs(items) do
    result[#result + 1] = item.id
  end
  return result
end

return {
  {
    name = "property: deterministic order survives repeated shuffles",
    run = function()
      math.randomseed(20260825)
      local candidates = {}
      for index = 1, 80 do
        candidates[index] = {
          id = string.format("candidate-%03d", index),
          text = string.format("debug-%03d-list", index),
          source_order = index,
        }
      end
      local options = { category = "command", case_mode = "insensitive", allow_subsequence = true }
      local expected = ids(matcher.rank("d-l", candidates, options))
      for _ = 1, 50 do
        assert.same(expected, ids(matcher.rank("d-l", shuffled(candidates), options)))
      end
    end,
  },
  {
    name = "property: exact match dominates every generated extension",
    run = function()
      local candidates = { { id = "exact", text = "TargetValue", source_order = 100 } }
      for index = 1, 100 do
        candidates[#candidates + 1] = {
          id = "extension-" .. index,
          text = "TargetValue" .. string.rep("x", index),
          source_order = index,
        }
      end
      local ranked = matcher.rank("TargetValue", candidates, { category = "command", case_mode = "sensitive" })
      assert.same("exact", ranked[1].id)
      assert.same("exact", ranked[1].match.level)
    end,
  },
  {
    name = "property: generated UTF-8 spans stay in bounds",
    run = function()
      local candidates = { "ÉtudeFindFile", "界ValueName", "café-au-lait", "Alpha2Beta" }
      local queries = { "éff", "界v-na", "ca-au-la", "a2b" }
      for index, candidate in ipairs(candidates) do
        local match = matcher.match(queries[index], candidate, {
          category = "command",
          case_mode = "insensitive",
        })
        assert.truthy(match, candidate)
        local previous_end = 0
        for _, span in ipairs(match.spans) do
          assert.truthy(span[1] >= previous_end)
          assert.truthy(span[2] <= #candidate)
          assert.truthy(utf8.is_boundary(candidate, span[1]))
          assert.truthy(utf8.is_boundary(candidate, span[2]))
          previous_end = span[2]
        end
      end
    end,
  },
  {
    name = "property: many word boundaries remain bounded",
    run = function()
      local words = {}
      for index = 1, 120 do
        words[index] = "word" .. index
      end
      local candidate = table.concat(words, "-")
      local started = vim.uv.hrtime()
      local match = matcher.match("w1-w60-w120", candidate, {
        category = "command",
        case_mode = "sensitive",
      })
      local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
      assert.truthy(match)
      assert.truthy(elapsed_ms < 250, string.format("adversarial word match took %.2f ms", elapsed_ms))
    end,
  },
}
