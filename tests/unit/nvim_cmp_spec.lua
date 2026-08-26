local nvim_cmp = require("partial_completion.adapters.nvim_cmp")
local assert = require("tests.helpers.assertions")

local function update(request, label, done)
  return {
    api_version = 1,
    request_id = 21,
    generation = 21,
    replacement = request.replacement,
    items = {
      {
        id = label,
        source = "filesystem",
        label = label,
        insert_text = label,
        kind = "file",
        data = { path = "/tmp/" .. label },
        match = {
          score = 1,
          level = "component_prefix",
          spans = { { 0, 2 } },
        },
      },
    },
    is_incomplete = not done,
    done = done,
  }
end

local function params(line, cursor_byte, mode)
  return {
    context = {
      mode = mode or "default",
      bufnr = 0,
      cursor_line = line,
      cursor = {
        row = 1,
        col = cursor_byte + 1,
      },
    },
  }
end

return {
  {
    name = "nvim-cmp source exposes UTF-8 path triggers and debug identity",
    run = function()
      local source = nvim_cmp.new({ cwd = "/tmp" })
      assert.same("partial-completion", source:get_debug_name())
      assert.same("utf-8", source:get_position_encoding_kind())
      assert.truthy(string.find(source:get_keyword_pattern(), "blank", 1, true))
      assert.same({ "/", ".", "\\", "~", "$" }, source:get_trigger_characters())
    end,
  },
  {
    name = "nvim-cmp comparator preserves core ordinal before host history",
    run = function()
      local function entry(ordinal)
        return {
          completion_item = {
            data = { partial_completion = { ordinal = ordinal } },
          },
        }
      end
      assert.truthy(nvim_cmp.compare(entry(1), entry(2)))
      assert.falsy(nvim_cmp.compare(entry(2), entry(1)))
      assert.same(nil, nvim_cmp.compare(entry(1), {}))
    end,
  },
  {
    name = "nvim-cmp source cancels stale work and maps terminal replacement and incompleteness",
    run = function()
      local requests = {}
      local source = nvim_cmp.new({
        cwd = "/tmp",
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
      local old_response
      local response
      source:complete(params("open old", 8), function(value)
        old_response = value
      end)
      source:complete(params("open de/liZZ tail", 10), function(value)
        response = value
      end)
      assert.truthy(requests[1].cancelled)
      assert.same("de/li", requests[2].request.query)
      assert.same({ start_byte = 5, end_byte = 12 }, requests[2].request.replacement)
      requests[1].callback(update(requests[1].request, "obsolete", true))
      assert.same(nil, old_response)
      requests[2].callback(update(requests[2].request, "Desktop/Library", false))
      assert.same(nil, response)
      requests[2].callback(update(requests[2].request, "Desktop/Library", true))
      assert.truthy(response.isIncomplete)
      assert.same(1, response.items[1].kind)
      assert.same("Desktop/Library", response.items[1].textEdit.newText)
      assert.same({ line = 0, character = 5 }, response.items[1].textEdit.range.start)
      assert.same({ line = 0, character = 12 }, response.items[1].textEdit.range["end"])
      assert.same("de/li", response.items[1].filterText)
      assert.same({ 0, 2 }, response.items[1].data.partial_completion.spans[1])
      source:_install_lifecycle()
      source:complete(params("open next", 9), function() end)
      assert.falsy(requests[#requests].cancelled)
      vim.api.nvim_exec_autocmds("InsertLeave", {})
      assert.truthy(requests[#requests].cancelled)
      source:close()
    end,
  },
  {
    name = "nvim-cmp cmdline completion delegates full context and suffix range",
    run = function()
      local source = nvim_cmp.new({
        complete_cmdline = function(line, cursor, callback)
          assert.same("edit de/liZZ | echo", line)
          assert.same(10, cursor)
          local request = {
            query = "de/li",
            replacement = { start_byte = 5, end_byte = 12 },
          }
          callback(update(request, "Desktop/Library", true))
          return {
            cancel = function() end,
          }, request
        end,
      })
      local response
      source:complete(params("edit de/liZZ | echo", 10, "cmdline"), function(value)
        response = value
      end)
      assert.truthy(response ~= nil)
      assert.same({ line = 0, character = 5 }, response.items[1].textEdit.range.start)
      assert.same({ line = 0, character = 12 }, response.items[1].textEdit.range["end"])
    end,
  },
  {
    name = "nvim-cmp preserves quoted and escaped path tokens for host filtering and insertion",
    run = function()
      local requests = {}
      local source = nvim_cmp.new({
        cwd = "/tmp",
        complete = function(request, callback)
          requests[#requests + 1] = { request = request, callback = callback }
          return { cancel = function() end }
        end,
      })

      local quoted_line = 's = "My Documents/fiZZ" tail'
      local quoted_cursor = string.find(quoted_line, "fiZZ", 1, true) + 1
      local quoted_response
      source:complete(params(quoted_line, quoted_cursor), function(value)
        quoted_response = value
      end)
      assert.same("My Documents/fi", requests[1].request.query)
      requests[1].callback(update(requests[1].request, "My Documents/file.txt", true))
      assert.same("My Documents/fi", quoted_response.items[1].filterText)
      assert.same("My Documents/file.txt", quoted_response.items[1].textEdit.newText)

      local escaped_line = "open My\\ Documents/fiZZ tail"
      local escaped_response
      source:complete(params(escaped_line, 21), function(value)
        escaped_response = value
      end)
      assert.same("My Documents/fi", requests[2].request.query)
      requests[2].callback(update(requests[2].request, "My Documents/file.txt", true))
      assert.same("My\\ Documents/fi", escaped_response.items[1].filterText)
      assert.same("My\\ Documents/file.txt", escaped_response.items[1].textEdit.newText)
      assert.same({ line = 0, character = 5 }, escaped_response.items[1].textEdit.range.start)
      assert.same({ line = 0, character = 23 }, escaped_response.items[1].textEdit.range["end"])
    end,
  },
  {
    name = "nvim-cmp accepts expected post-edit state and reports genuinely stale execution",
    run = function()
      local errors = {}
      local source = nvim_cmp.new({
        cwd = "/tmp",
        on_error = function(message)
          errors[#errors + 1] = message
        end,
        complete = function(request, callback)
          callback(update(request, "Desktop/Library", true))
          return { cancel = function() end }
        end,
      })
      local response
      source:complete(params("open de/liZZ tail", 10), function(value)
        response = value
      end)

      local original_line = vim.api.nvim_get_current_line()
      local original_cursor = vim.api.nvim_win_get_cursor(0)
      local ok, err = xpcall(function()
        vim.api.nvim_set_current_line("open Desktop/Library tail")
        vim.api.nvim_win_set_cursor(0, { 1, 5 + #"Desktop/Library" })
        local callbacks = 0
        source:execute(response.items[1], function()
          callbacks = callbacks + 1
        end)
        assert.same({}, errors)

        vim.api.nvim_set_current_line("open changed tail")
        vim.api.nvim_win_set_cursor(0, { 1, 12 })
        source:execute(response.items[1], function()
          callbacks = callbacks + 1
        end)
        assert.same(2, callbacks)
        assert.same({ "stale completion context" }, errors)
      end, debug.traceback)
      vim.api.nvim_set_current_line(original_line)
      vim.api.nvim_win_set_cursor(0, original_cursor)
      assert.truthy(ok, err)
    end,
  },
  {
    name = "nvim-cmp guarded registration is harmless when dependency is absent",
    run = function()
      local loaded = package.loaded.cmp
      package.loaded.cmp = nil
      local id, err = nvim_cmp.register()
      assert.same(nil, id)
      assert.same("nvim-cmp is unavailable", err)
      package.loaded.cmp = loaded
    end,
  },
}
