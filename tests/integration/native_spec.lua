local assert = require("tests.helpers.assertions")
local completion = require("partial_completion")

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end

local function partial_autocmd_count()
  local count = 0
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({})) do
    if type(autocmd.group_name) == "string" and string.find(autocmd.group_name, "^PartialCompletionCmdline") then
      count = count + 1
    end
  end
  return count
end

return {
  {
    name = "public session streams early engine updates and preserves selection",
    run = function()
      completion.register_provider("phase-five-stream", {
        api_version = 1,
        categories = { "generic" },
        complete = function(_, emit, done)
          local active = true
          vim.schedule(function()
            if not active then
              return
            end
            emit({
              { id = "alpha", label = "alpha", insert_text = "alpha" },
              { id = "alpine", label = "alpine", insert_text = "alpine" },
            })
            vim.schedule(function()
              if not active then
                return
              end
              emit({ { id = "aardvark", label = "aardvark", insert_text = "aardvark" } })
              done(nil)
            end)
          end)
          return {
            cancel = function()
              active = false
            end,
          }
        end,
      })

      local update_count = 0
      local active
      active = completion.new_session({
        on_change = function(_, event)
          if event == "update" then
            update_count = update_count + 1
            if update_count == 1 then
              active:select("alpine", "phase-five-stream")
            end
          end
        end,
      })
      active:start({ category = "generic", query = "a", provider = "phase-five-stream" })
      assert.truthy(vim.wait(2000, function()
        return active:snapshot().done
      end, 1))
      assert.truthy(update_count >= 3)
      assert.same("alpine", active:selected_item().id)
      local labels = {}
      for _, candidate in ipairs(active:snapshot().items) do
        labels[candidate.id] = true
      end
      assert.truthy(labels.aardvark)
      active:close()
    end,
  },
  {
    name = "native enablement preserves command macros and tears down without leaks",
    run = function()
      local buffers_before = #vim.api.nvim_list_bufs()
      local autocmds_before = partial_autocmd_count()
      vim.keymap.set("c", "<F7>", "ORIGINAL", { desc = "phase five original mapping" })

      local native_options = {
        enabled = true,
        max_items = 5,
        mappings = {
          next = "<F7>",
          previous = "<F8>",
          accept = "<F9>",
          cancel = "<F10>",
        },
      }
      completion.setup({ native = native_options })
      assert.truthy(partial_autocmd_count() > autocmds_before)
      local enabled_autocmds = partial_autocmd_count()
      completion.setup({ native = native_options })
      assert.same(enabled_autocmds, partial_autocmd_count())
      assert.truthy(vim.fn.exists(":PartialCompletionEnable") == 2)
      assert.truthy(vim.fn.exists(":PartialCompletionDisable") == 2)
      assert.truthy(vim.fn.exists(":PartialCompletionToggle") == 2)

      vim.fn.setreg("q", ":let g:phase_five_macro = 1\r")
      feed("@q")
      assert.same(1, vim.g.phase_five_macro)
      assert.same(nil, completion.native_state())
      assert.same("ORIGINAL", vim.fn.maparg("<F7>", "c"))

      completion.setup({})
      assert.falsy(completion.native_enabled())
      assert.same(autocmds_before, partial_autocmd_count())
      assert.same(buffers_before, #vim.api.nvim_list_bufs())
      assert.same("ORIGINAL", vim.fn.maparg("<F7>", "c"))

      pcall(vim.keymap.del, "c", "<F7>")
      vim.fn.setreg("q", "")
      vim.g.phase_five_macro = nil
    end,
  },
}
