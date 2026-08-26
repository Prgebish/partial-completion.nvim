local assert = require("tests.helpers.assertions")
local config = require("partial_completion.config")
local native = require("partial_completion.adapters.native")

local function native_config()
  return config.resolve({
    native = {
      max_items = 2,
      min_width = 10,
      max_width = 40,
      mappings = {
        next = "<F7>",
        previous = "<F8>",
        accept = "<F9>",
        cancel = "<F10>",
      },
    },
  }).native
end

return {
  {
    name = "native configuration validates bounds mappings and request options",
    run = function()
      local resolved = native_config()
      assert.same(2, resolved.max_items)
      assert.same("<F9>", resolved.mappings.accept)
      assert.raises("native.max_items", function()
        config.resolve({ native = { max_items = 0 } })
      end)
      assert.raises("native mappings must be unique", function()
        config.resolve({
          native = {
            mappings = { next = "<Tab>", previous = "<Tab>" },
          },
        })
      end)
      local request = config.resolve({
        native = {
          request = {
            cwd = "/tmp",
            home = "/tmp/home",
            env = { ROOT = "/tmp" },
            search_roots = { "vendor" },
            case_mode = "filesystem",
            filesystem_case_sensitive = { ["/tmp"] = true },
          },
        },
      }).native.request
      assert.same("filesystem", request.case_mode)
      assert.truthy(request.filesystem_case_sensitive["/tmp"])
      assert.raises("dense list", function()
        config.resolve({ native = { request = { search_roots = { [2] = "vendor" } } } })
      end)
      assert.raises("dense list", function()
        config.resolve({ native = { request = { search_roots = { "vendor", label = "hidden" } } } })
      end)
    end,
  },
  {
    name = "native adapter renders bounded snapshots highlights and selection",
    run = function()
      local controller_options
      local calls = { start = 0, stop = 0, selection = 0 }
      local controller = {
        start = function()
          calls.start = calls.start + 1
        end,
        stop = function()
          calls.stop = calls.stop + 1
        end,
        state = function()
          return nil
        end,
        select_next = function(_, delta)
          calls.selection = calls.selection + delta
        end,
      }
      local adapter = native.new({
        config = native_config(),
        new_controller = function(options)
          controller_options = options
          return controller
        end,
      })
      adapter:start()
      assert.same(1, calls.start)
      controller_options.on_state({
        status = "active",
        selected_id = "alpha",
        selected_source = "test",
        is_incomplete = true,
        items = {
          {
            id = "alpha",
            source = "test",
            label = "alphabet",
            insert_text = "alphabet",
            match = { spans = { { 0, 3 } } },
          },
          {
            id = "alpine",
            source = "test",
            label = "alpine\nline",
            detail = "detail\rline",
            insert_text = "alpine\nline",
          },
          { id = "atlas", source = "test", label = "atlas", insert_text = "atlas" },
        },
      }, { cmdtype = ":", replacement = { start_byte = 4, end_byte = 7 } })

      assert.truthy(vim.wait(1000, function()
        return adapter:is_visible()
      end, 1))
      assert.truthy(adapter:is_visible())
      local rendered = {}
      for _, chunk in ipairs(adapter.last_chunks) do
        rendered[#rendered + 1] = chunk[1]
      end
      assert.truthy(string.find(table.concat(rendered), "alphabet", 1, true))
      local rendered_text = table.concat(rendered)
      assert.truthy(string.find(rendered_text, "alpine line", 1, true))
      assert.truthy(string.find(rendered_text, "detail line", 1, true))
      assert.falsy(string.find(rendered_text, "\n", 1, true))
      adapter:select_next(1)
      assert.same(1, calls.selection)
      adapter:stop()
      assert.same(1, calls.stop)
      assert.falsy(adapter:is_visible())
    end,
  },
  {
    name = "native adapter restores pre-existing command-line mappings",
    run = function()
      vim.keymap.set("c", "<F7>", "ORIGINAL", { desc = "original mapping" })
      local controller = {
        start = function() end,
        stop = function() end,
        state = function()
          return nil
        end,
      }
      local adapter = native.new({
        config = native_config(),
        new_controller = function()
          return controller
        end,
      })
      adapter:start()
      adapter:render({
        status = "active",
        selected_id = "alpha",
        selected_source = "test",
        items = { { id = "alpha", source = "test", label = "alpha", insert_text = "alpha" } },
      }, { cmdtype = ":", replacement = { start_byte = 0, end_byte = 1 } })
      assert.truthy(string.find(vim.fn.maparg("<F7>", "c"), "Lua", 1, true))
      adapter:close_menu()
      assert.same("ORIGINAL", vim.fn.maparg("<F7>", "c"))
      adapter:stop()
      pcall(vim.keymap.del, "c", "<F7>")
    end,
  },
  {
    name = "native render failures close stale presentation",
    run = function()
      local reported
      local adapter = native.new({
        config = native_config(),
        new_controller = function()
          return {
            start = function() end,
            stop = function() end,
            state = function()
              return nil
            end,
          }
        end,
        on_error = function(err)
          reported = tostring(err)
        end,
      })
      adapter:start()
      adapter:render({
        status = "active",
        selected_id = "alpha",
        selected_source = "test",
        items = { { id = "alpha", source = "test", label = "alpha", insert_text = "alpha" } },
      }, { cmdtype = ":" })
      assert.truthy(adapter:is_visible())
      adapter.render = function()
        error("render-sentinel")
      end
      adapter:queue_render({
        status = "active",
        selected_id = "alpha",
        selected_source = "test",
        items = { { id = "alpha", source = "test", label = "alpha", insert_text = "alpha" } },
      }, { cmdtype = ":" })
      assert.truthy(vim.wait(1000, function()
        return reported ~= nil
      end, 1))
      assert.falsy(adapter:is_visible())
      assert.truthy(string.find(reported, "render-sentinel", 1, true))
      adapter:stop()
    end,
  },
}
