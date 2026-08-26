local assert = require("tests.helpers.assertions")
local completion = require("partial_completion")
local filesystem = require("partial_completion.providers.filesystem")
local static = require("partial_completion.providers.static")

-- Warm the module-owned namespace before the runner takes per-test snapshots.
require("partial_completion.adapters.native")

local function close_timer(timer)
  if timer ~= nil and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

return {
  {
    name = "simulated network provider cancellation keeps the event loop responsive",
    run = function()
      completion.register_provider("phase-seven-network", {
        api_version = 1,
        categories = { "generic" },
        complete = function(_, emit, done)
          local active = true
          local timer = vim.uv.new_timer()
          timer:start(200, 0, function()
            vim.schedule(function()
              if active then
                emit({ { id = "remote", label = "remote", insert_text = "remote" } })
                done(nil)
              end
              close_timer(timer)
            end)
          end)
          return {
            cancel = function()
              active = false
              close_timer(timer)
            end,
          }
        end,
      })

      local ticks = 0
      local heartbeat = vim.uv.new_timer()
      heartbeat:start(0, 1, function()
        ticks = ticks + 1
      end)
      local updates = 0
      local handle = completion.complete({
        category = "generic",
        query = "re",
        provider = "phase-seven-network",
      }, function()
        updates = updates + 1
      end)
      assert.truthy(
        vim.wait(50, function()
          return ticks >= 5
        end, 1),
        "event loop did not advance during simulated network latency"
      )
      handle:cancel()
      assert.truthy(vim.wait(30, function()
        return ticks >= 10
      end, 1))
      close_timer(heartbeat)
      assert.same(0, updates)
    end,
  },
  {
    name = "repeated sessions and native lifecycle release every owned resource",
    run = function()
      completion.register_provider(
        "phase-seven-repeat",
        static.new({
          { id = "alpha", label = "alpha", insert_text = "alpha" },
        })
      )
      for _ = 1, 100 do
        local session = completion.new_session()
        session:start({ category = "generic", query = "a", provider = "phase-seven-repeat" })
        assert.truthy(session:snapshot().done)
        session:close()
      end

      for _ = 1, 30 do
        completion.enable_native({
          mappings = { next = false, previous = false, accept = false, cancel = false },
        })
        completion.disable_native()
      end

      local root = vim.fn.tempname()
      vim.fn.mkdir(root, "p")
      for index = 1, 200 do
        vim.fn.writefile({ "fixture" }, string.format("%s/item-%03d.txt", root, index))
      end
      local provider = filesystem.new({ scan_chunk_size = 1, cache = { ttl_ms = 0 } })
      for _ = 1, 30 do
        local handle = provider.complete({
          category = "path",
          query = "i",
          cwd = root,
          case_mode = "insensitive",
          limit = 20,
          context = { platform = "posix" },
        }, function() end, function() end)
        handle:cancel()
      end
      assert.truthy(vim.wait(1000, function()
        local active = false
        vim.uv.walk(function(handle)
          if handle:is_active() and string.find(tostring(handle), "fs", 1, true) then
            active = true
          end
        end)
        return not active
      end, 1))
      vim.fn.delete(root, "rf")
      completion.setup({})
    end,
  },
}
