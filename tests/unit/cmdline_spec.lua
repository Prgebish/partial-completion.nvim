local assert = require("tests.helpers.assertions")
local cmdline = require("partial_completion.cmdline")

local function context(query)
  return {
    status = "ok",
    source_text = query,
    cursor_byte = #query,
    query = query,
    replacement = { start_byte = 0, end_byte = #query },
    category = "generic",
    completion_type = "customlist,Test",
    cmdtype = ":",
  }
end

return {
  {
    name = "cmdline analysis delegates categories to Neovim completion types",
    run = function()
      local cases = {
        { "edi", "command", "command" },
        { "cd Di", "dir_in_path", "path" },
        { "set wildm", "option", "option" },
        { "buffer na", "buffer", "buffer" },
        { "help api", "help", "help" },
        { "call str", "function", "function" },
        { "unlet g:va", "var", "variable" },
        { "map <C-W>", "mapping", "mapping" },
        { "colorscheme da", "color", "generic" },
        { "!rg", "shellcmd", "generic" },
      }
      for _, case in ipairs(cases) do
        local actual = cmdline.analyze(case[1], #case[1], { live = false })
        assert.same(case[2], actual.completion_type, case[1])
        assert.same(case[3], actual.category, case[1])
      end
    end,
  },
  {
    name = "cmdline analysis replaces token suffixes and decodes escaped filenames",
    run = function()
      local midline = cmdline.analyze("edit ~/de/li.txt | keepalt", 12, {
        live = false,
        completion_type = "file",
        completion_pattern = "~/de/li.txt",
      })
      assert.same("~/de/li", midline.query)
      assert.same({ start_byte = 5, end_byte = 16 }, midline.replacement)

      local escaped = cmdline.analyze([[edit My\ Do | keepalt]], 11, {
        live = false,
        completion_type = "file",
      })
      assert.same("My Do", escaped.query)
      assert.same([[My\ Do]], escaped.raw_query)
      assert.same({ start_byte = 5, end_byte = 11 }, escaped.replacement)

      local apostrophe = cmdline.analyze("edit O'Re | keepalt", 9, {
        live = false,
        completion_type = "file",
      })
      assert.same("O'Re", apostrophe.query)
      assert.same(nil, apostrophe.quote)
      assert.same({ start_byte = 5, end_byte = 9 }, apostrophe.replacement)

      local option = cmdline.analyze("set wildmode", 9, {
        live = false,
        completion_type = "option",
      })
      assert.same("wildm", option.query)
      assert.same({ start_byte = 4, end_byte = 12 }, option.replacement)
    end,
  },
  {
    name = "cmdline encoding escapes filenames without destroying environment roots",
    run = function()
      local plain = { category = "path", completion_type = "file" }
      assert.same([[My\ Documents/\[draft]\*\?.txt]], cmdline.encode("My Documents/[draft]*?.txt", plain))
      assert.same([[$WORK/My\ File]], cmdline.encode("$WORK/My File", plain))
      local windows = { category = "path", completion_type = "file", platform = "windows" }
      assert.same([[$WORK\My\ File]], cmdline.encode([[$WORK\My File]], windows))
      assert.same([[O\'Reilly]], cmdline.encode("O'Reilly", plain))
      assert.same([[bad\|name]], cmdline.encode("bad|name", plain))

      local names = {
        "plain",
        "My Documents",
        "O'Reilly",
        "a|b",
        "<plus+greater>",
        [[back\slash]],
        "[draft]*?.txt",
      }
      for _, name in ipairs(names) do
        local encoded = cmdline.encode(name, plain)
        local source = "edit " .. encoded
        local decoded = cmdline.analyze(source, #source, {
          live = false,
          completion_type = "file",
        })
        assert.same(name, decoded.query, name)
      end
      for byte = 1, 127 do
        if byte ~= 47 then
          local name = "x" .. string.char(byte) .. "y"
          local encoded = cmdline.encode(name, plain)
          local source = "edit " .. encoded
          local decoded = cmdline.analyze(source, #source, {
            live = false,
            completion_type = "file",
          })
          assert.same(name, decoded.query, "POSIX filename byte " .. tostring(byte))
        end
      end
    end,
  },
  {
    name = "cmdline acceptance is atomic and rejects stale snapshots",
    run = function()
      local snapshot = {
        source_text = "edit ~/de | keepalt",
        cursor_byte = 9,
        replacement = { start_byte = 5, end_byte = 9 },
        generation = 3,
        cmdtype = ":",
        cmdlevel = 1,
      }
      local accepted = select(1, cmdline.accept({ insert_text = "~/Desktop/" }, snapshot, vim.deepcopy(snapshot)))
      assert.same("edit ~/Desktop/ | keepalt", accepted.source_text)
      assert.same(15, accepted.cursor_byte)
      local changed = vim.deepcopy(snapshot)
      changed.source_text = "edit ~/dev | keepalt"
      changed.cursor_byte = 10
      local result, err = cmdline.accept({ insert_text = "~/Desktop/" }, snapshot, changed)
      assert.same(nil, result)
      assert.same("stale_context", err)

      snapshot = {
        source_text = "edit li.txt | keepalt",
        cursor_byte = 7,
        replacement = { start_byte = 5, end_byte = 11 },
        generation = 4,
        cmdtype = ":",
        cmdlevel = 1,
      }
      accepted = select(1, cmdline.accept({ insert_text = "license.txt" }, snapshot, vim.deepcopy(snapshot)))
      assert.same("edit license.txt | keepalt", accepted.source_text)

      changed = vim.deepcopy(snapshot)
      changed.replacement.start_byte = 6
      result, err = cmdline.accept({ insert_text = "~/Desktop/" }, snapshot, changed)
      assert.same(nil, result)
      assert.same("stale_context", err)
    end,
  },
  {
    name = "cmdline controller makes latest generation and nested level authoritative",
    run = function()
      local callbacks = {}
      local handles = {}
      local observed = {}
      local states = {}
      local controller = cmdline.new_controller({
        complete = function(_, callback)
          callbacks[#callbacks + 1] = callback
          local handle = { cancelled = false }
          function handle:cancel()
            self.cancelled = true
          end
          handles[#handles + 1] = handle
          return handle
        end,
        on_update = function(update, request_context)
          observed[#observed + 1] = { update = update, context = request_context }
        end,
        on_state = function(state, _, event)
          if event == "update" then
            states[#states + 1] = state
          end
        end,
      })

      controller:request(context("a"), 1)
      controller:request(context("ab"), 1)
      assert.truthy(handles[1].cancelled)
      callbacks[1]({ generation = 1 })
      callbacks[2]({ generation = 2 })
      assert.same(1, #observed)
      assert.same("ab", observed[1].context.query)
      assert.same(2, states[1].generation)

      controller:request(context("nested"), 2)
      assert.truthy(handles[2].cancelled)
      callbacks[2]({ generation = 2 })
      callbacks[3]({ generation = 3 })
      assert.same(2, #observed)
      assert.same("nested", observed[2].context.query)
      assert.same(3, states[2].generation)
      controller:stop()
      assert.truthy(handles[3].cancelled)
    end,
  },
  {
    name = "stale acceptance immediately refreshes the live context",
    run = function()
      local callbacks = {}
      local controller = cmdline.new_controller({
        complete = function(_, callback)
          callbacks[#callbacks + 1] = callback
          return { cancel = function() end }
        end,
      })
      local initial = context("a")
      initial.completion_type = "customlist,Test"
      initial.cmdlevel = 1
      controller:request(initial, 1)
      callbacks[1]({
        request_id = 1,
        generation = 1,
        items = { { id = "alpha", source = "test", label = "alpha", insert_text = "alpha" } },
        done = true,
      })

      local original_capture = cmdline.capture
      local capture_count = 0
      local ok, err = xpcall(function()
        cmdline.capture = function()
          capture_count = capture_count + 1
          if capture_count == 1 then
            local stale = vim.deepcopy(initial)
            stale.source_text = "changed"
            stale.cursor_byte = #stale.source_text
            stale.replacement = { start_byte = 0, end_byte = #stale.source_text }
            return stale
          end
          local fresh = context("changed")
          fresh.completion_type = "customlist,Test"
          fresh.cmdlevel = 1
          return fresh
        end
        local accepted, accept_error = controller:accept()
        assert.same(nil, accepted)
        assert.same("stale_context", accept_error)
        assert.same(2, #callbacks)
        assert.same("changed", controller:state().request.query)
      end, debug.traceback)
      cmdline.capture = original_capture
      controller:stop()
      if not ok then
        error(err, 0)
      end
    end,
  },
  {
    name = "reentrant on_context cannot start an unowned provider request",
    run = function()
      local complete_queries = {}
      local handles = {}
      local controller
      local reenter = true
      controller = cmdline.new_controller({
        complete = function(request_value)
          complete_queries[#complete_queries + 1] = request_value.query
          local handle = { cancelled = false }
          function handle:cancel()
            self.cancelled = true
          end
          handles[#handles + 1] = handle
          return handle
        end,
        on_context = function(value)
          if value.query == "stop" then
            controller:stop()
          elseif value.query == "outer" and reenter then
            reenter = false
            controller:request(context("inner"), 1)
          end
        end,
      })

      assert.same(nil, controller:request(context("stop"), 1))
      assert.same({}, complete_queries)
      assert.same(nil, controller.active_level)

      assert.same(nil, controller:request(context("outer"), 1))
      assert.same({ "inner" }, complete_queries)
      assert.same("inner", controller:state().request.query)
      controller:stop()
      assert.truthy(handles[1].cancelled)
    end,
  },
}
