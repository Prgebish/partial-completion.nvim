local blink = require("partial_completion.adapters.blink")
local assert = require("tests.helpers.assertions")

local function update(request, item, incomplete, identity)
  identity = identity or 11
  return {
    api_version = 1,
    request_id = identity,
    generation = identity,
    replacement = request.replacement,
    items = {
      {
        id = "result",
        source = "filesystem",
        label = item,
        insert_text = item,
        kind = "file",
        data = { path = "/tmp/" .. item },
        match = {
          score = 1,
          level = "component_prefix",
          spans = { { 0, 2 } },
        },
      },
    },
    is_incomplete = incomplete == true,
    done = not incomplete,
  }
end

return {
  {
    name = "Blink label highlighter renders every core span and preserves host fallback",
    run = function()
      local highlights = blink.label_highlight({
        label = "Desktop/Library/Unsorted/",
        label_detail = " directory",
        label_matched_indices = { 19 },
        deprecated = false,
        item = {
          data = {
            partial_completion = {
              spans = { { 0, 1 }, { 8, 9 }, { 16, 17 } },
            },
          },
        },
      })
      assert.same({ 0, #"Desktop/Library/Unsorted/", group = "BlinkCmpLabel" }, highlights[1])
      assert.same(
        { #"Desktop/Library/Unsorted/", #"Desktop/Library/Unsorted/ directory", group = "BlinkCmpLabelDetail" },
        highlights[2]
      )
      assert.same({ 0, 1, group = "BlinkCmpLabelMatch" }, highlights[3])
      assert.same({ 8, 9, group = "BlinkCmpLabelMatch" }, highlights[4])
      assert.same({ 16, 17, group = "BlinkCmpLabelMatch" }, highlights[5])

      local fallback = blink.label_highlight({
        label = "ordinary",
        label_detail = "",
        label_matched_indices = { 1, 4 },
        item = {},
      })
      assert.same({ 1, 2, group = "BlinkCmpLabelMatch" }, fallback[2])
      assert.same({ 4, 5, group = "BlinkCmpLabelMatch" }, fallback[3])
    end,
  },
  {
    name = "Blink source automatically wraps the active host label renderer",
    run = function()
      local original_config = package.loaded["blink.cmp.config"]
      local calls = 0
      local original_highlight = function()
        calls = calls + 1
        return {
          { 0, 20, group = "CustomBase" },
          { 16, 17, group = "BlinkCmpLabelMatch" },
        }
      end
      local blink_config = {
        completion = {
          menu = {
            draw = {
              components = {
                label = { highlight = original_highlight },
              },
            },
          },
        },
      }
      package.loaded["blink.cmp.config"] = blink_config

      local ok, err = xpcall(function()
        blink.new({ cwd = "/tmp" })
        local installed = blink_config.completion.menu.draw.components.label.highlight
        assert.truthy(installed ~= original_highlight)
        blink.new({ cwd = "/tmp" })
        assert.same(installed, blink_config.completion.menu.draw.components.label.highlight)
        local highlights = installed({
          label = "Desktop/Library/Unsorted/",
          item = {
            data = {
              partial_completion = {
                spans = { { 0, 1 }, { 8, 9 }, { 16, 17 } },
              },
            },
          },
        })
        assert.same(1, calls)
        assert.same({ 0, 20, group = "CustomBase" }, highlights[1])
        assert.same({ 0, 1, group = "BlinkCmpLabelMatch" }, highlights[2])
        assert.same({ 8, 9, group = "BlinkCmpLabelMatch" }, highlights[3])
        assert.same({ 16, 17, group = "BlinkCmpLabelMatch" }, highlights[4])

        local unrelated = installed({ label = "ordinary", item = {} })
        assert.same(2, calls)
        assert.same({ 0, 20, group = "CustomBase" }, unrelated[1])
        assert.same({ 16, 17, group = "BlinkCmpLabelMatch" }, unrelated[2])

        local transformed = installed({
          label = "Desktop/Library/Unsorted/",
          item = {
            data = {
              partial_completion = {
                spans = { { 0, 1 }, { 8, 9 }, { 16, 17 } },
              },
            },
          },
        }, "transformed label")
        assert.same(3, calls)
        assert.same({ 0, 20, group = "CustomBase" }, transformed[1])
        assert.same({ 16, 17, group = "BlinkCmpLabelMatch" }, transformed[2])

        blink_config.completion.menu.draw.components.label.highlight = original_highlight
        blink.new({ cwd = "/tmp", auto_highlight = false })
        assert.same(original_highlight, blink_config.completion.menu.draw.components.label.highlight)
        assert.raises("auto_highlight", function()
          blink.new({ cwd = "/tmp", auto_highlight = "yes" })
        end)
      end, debug.traceback)

      package.loaded["blink.cmp.config"] = original_config
      assert.truthy(ok, err)
    end,
  },
  {
    name = "Blink insert source maps core result to exact text edit and cancellation",
    run = function()
      local observed_request
      local observed_callback
      local cancelled = 0
      local source = blink.new({
        cwd = "/tmp",
        complete = function(request, callback)
          observed_request = request
          observed_callback = callback
          return {
            cancel = function()
              cancelled = cancelled + 1
            end,
          }
        end,
      })
      local responses = {}
      local cancel = source:get_completions({
        mode = "default",
        bufnr = 0,
        line = "open de/liZZ tail",
        cursor = { 1, 10 },
      }, function(response)
        responses[#responses + 1] = response
      end)
      assert.same("de/li", observed_request.query)
      assert.same({ start_byte = 5, end_byte = 12 }, observed_request.replacement)
      observed_callback(update(observed_request, "Desktop/Library", true))
      assert.same({}, responses)
      observed_callback(update(observed_request, "Desktop/Library", false))
      assert.same(1, #responses)
      assert.same("Desktop/Library", responses[1].items[1].textEdit.newText)
      assert.same({ line = 0, character = 5 }, responses[1].items[1].textEdit.range.start)
      assert.same({ line = 0, character = 12 }, responses[1].items[1].textEdit.range["end"])
      assert.truthy(responses[1].is_incomplete_forward)
      assert.same({ 0, 2 }, responses[1].items[1].data.partial_completion.spans[1])
      local applied = 0
      local resolved = 0
      source:execute(
        {
          line = "open de/liZZ tail",
          cursor = { 1, 10 },
          get_line = function()
            return "open de/liZZ tail"
          end,
          get_cursor = function()
            return { 1, 10 }
          end,
        },
        responses[1].items[1],
        function()
          resolved = resolved + 1
        end,
        function()
          applied = applied + 1
        end
      )
      source:execute(
        {
          line = "open de/liZZ tail",
          cursor = { 1, 10 },
          get_line = function()
            return "open changed tail"
          end,
          get_cursor = function()
            return { 1, 12 }
          end,
        },
        responses[1].items[1],
        function()
          resolved = resolved + 1
        end,
        function()
          applied = applied + 1
        end
      )
      assert.same(1, applied)
      assert.same(2, resolved)
      cancel()
      cancel()
      assert.same(1, cancelled)
    end,
  },
  {
    name = "Blink cmdline source delegates context and retains replacement range",
    run = function()
      local source = blink.new({
        complete_cmdline = function(line, cursor, callback)
          assert.same("edit de/liZZ | echo", line)
          assert.same(10, cursor)
          local request = {
            query = "de/li",
            replacement = { start_byte = 5, end_byte = 12 },
          }
          callback(update(request, "Desktop/Library", false))
          return {
            cancel = function() end,
          }, {
            query = "de/li",
            replacement = request.replacement,
          }
        end,
      })
      local response
      source:get_completions({
        mode = "cmdline",
        line = "edit de/liZZ | echo",
        cursor = { 1, 10 },
      }, function(value)
        response = value
      end)
      assert.truthy(response ~= nil)
      assert.same({ line = 0, character = 5 }, response.items[1].textEdit.range.start)
      assert.same({ line = 0, character = 12 }, response.items[1].textEdit.range["end"])
    end,
  },
  {
    name = "Blink insert source completes a path inside string quotes without replacing delimiters",
    run = function()
      local observed_request
      local observed_callback
      local source = blink.new({
        cwd = "/tmp",
        complete = function(request, callback)
          observed_request = request
          observed_callback = callback
          return { cancel = function() end }
        end,
      })
      local line = "s = '~/My Documents/fiZZ' tail"
      local cursor_byte = string.find(line, "fiZZ", 1, true) + 1
      local response
      source:get_completions({
        mode = "default",
        bufnr = 0,
        line = line,
        cursor = { 1, cursor_byte },
      }, function(value)
        response = value
      end)
      assert.same("~/My Documents/fi", observed_request.query)
      assert.same({ start_byte = 5, end_byte = 24 }, observed_request.replacement)
      observed_callback(update(observed_request, "~/My Documents/file.txt", false))
      assert.truthy(response ~= nil)
      assert.same("~/My Documents/file.txt", response.items[1].textEdit.newText)
      assert.same({ line = 0, character = 5 }, response.items[1].textEdit.range.start)
      assert.same({ line = 0, character = 24 }, response.items[1].textEdit.range["end"])
    end,
  },
  {
    name = "Blink rejects an ABA-stale item even when line and cursor repeat",
    run = function()
      local callbacks = {}
      local errors = {}
      local source = blink.new({
        cwd = "/tmp",
        on_error = function(message)
          errors[#errors + 1] = message
        end,
        complete = function(_, callback)
          callbacks[#callbacks + 1] = callback
          return { cancel = function() end }
        end,
      })
      local context = {
        mode = "default",
        bufnr = 0,
        line = "open de/li",
        cursor = { 1, 10 },
        get_line = function()
          return "open de/li"
        end,
        get_cursor = function()
          return { 1, 10 }
        end,
      }
      local first
      source:get_completions(context, function(value)
        first = value
      end)
      callbacks[1](update({ replacement = { start_byte = 5, end_byte = 10 } }, "Desktop/Library", false, 31))

      local second
      source:get_completions(context, function(value)
        second = value
      end)
      callbacks[2](update({ replacement = { start_byte = 5, end_byte = 10 } }, "Desktop/Library", false, 32))

      local applied = 0
      local resolved = 0
      local function resolve()
        resolved = resolved + 1
      end
      local function apply()
        applied = applied + 1
      end
      source:execute(context, first.items[1], resolve, apply)
      source:execute(context, second.items[1], resolve, apply)
      assert.same(1, applied)
      assert.same(2, resolved)
      assert.same({ "stale completion context" }, errors)
    end,
  },
  {
    name = "Blink source module loads without Blink installed",
    run = function()
      local loaded = package.loaded["blink.cmp"]
      package.loaded["blink.cmp"] = nil
      assert.truthy(require("partial_completion.adapters.blink").new({ cwd = "/tmp" }))
      package.loaded["blink.cmp"] = loaded
    end,
  },
}
