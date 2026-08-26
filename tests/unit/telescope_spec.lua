local telescope = require("partial_completion.adapters.telescope")
local assert = require("tests.helpers.assertions")

local function update(label, done)
  return {
    api_version = 1,
    request_id = 1,
    generation = 1,
    items = {
      {
        id = label,
        source = "test",
        label = label,
        insert_text = label,
        kind = "file",
        data = { path = "/tmp/" .. label },
        match = {
          score = 1,
          level = "prefix",
          spans = { { 0, 2 } },
        },
      },
    },
    is_incomplete = not done,
    done = done,
  }
end

return {
  {
    name = "Telescope entries display core spans and sorter consumes core score",
    run = function()
      local entry = telescope.entry(update("alpha", true).items[1])
      local display, highlights = entry.display(entry)
      assert.same("alpha", display)
      assert.same({ { { 0, 2 }, "TelescopeMatching" } }, highlights)
      assert.same("/tmp/alpha", entry.path)

      local sorter = telescope.new_sorter({
        sorters = {
          new = function(options)
            return options
          end,
        },
      })
      assert.same(1, sorter.scoring_function(nil, "", entry.ordinal, entry))
      entry.value.match.score = 4
      assert.same(0.25, sorter.scoring_function(nil, "", entry.ordinal, entry))
    end,
  },
  {
    name = "Telescope dynamic finder cancels stale requests and emits terminal snapshot once",
    run = function()
      local requests = {}
      local finder = telescope.new_finder({
        request = function(prompt)
          return { query = prompt }
        end,
        on_error = function(message)
          error(message)
        end,
        complete = function(request, callback)
          local state = {
            request = request,
            callback = callback,
            cancelled = false,
          }
          requests[#requests + 1] = state
          return {
            cancel = function()
              state.cancelled = true
            end,
          }
        end,
      })

      local results = {}
      local completed = 0
      finder("old", function(entry)
        results[#results + 1] = entry.value.label
      end, function()
        completed = completed + 1
      end)
      finder("new", function(entry)
        results[#results + 1] = entry.value.label
      end, function()
        completed = completed + 1
      end)
      assert.truthy(requests[1].cancelled)
      requests[1].callback(update("old", true))
      requests[2].callback(update("new", false))
      assert.same({}, results)
      requests[2].callback(update("new", true))
      assert.same({ "new" }, results)
      assert.same(1, completed)
      finder:close()
    end,
  },
  {
    name = "Telescope adapter loads without Telescope installed",
    run = function()
      local loaded = package.loaded["telescope"]
      package.loaded["telescope"] = nil
      assert.truthy(require("partial_completion.adapters.telescope"))
      package.loaded["telescope"] = loaded
    end,
  },
}
