local adapters = require("partial_completion.adapters")
local assert = require("tests.helpers.assertions")

local function update(overrides)
  return vim.tbl_deep_extend("force", {
    api_version = 1,
    request_id = 7,
    generation = 7,
    replacement = { start_byte = 2, end_byte = 7 },
    items = {
      {
        id = "first",
        source = "values",
        label = "Desktop/Library/",
        insert_text = "Desktop/Library/",
        kind = "directory",
        data = { path = "/tmp/Desktop/Library" },
        match = {
          score = 2,
          level = "component_prefix",
          spans = {
            { 0, 2 },
            { 8, 10 },
          },
        },
      },
      {
        id = "second",
        source = "values",
        label = "Delta/Links/",
        insert_text = "Delta/Links/",
        kind = "directory",
        data = {},
        match = {
          score = 1,
          level = "component_prefix",
          spans = {
            { 0, 2 },
            { 6, 8 },
          },
        },
      },
    },
    is_incomplete = false,
    done = true,
  }, overrides or {})
end

return {
  {
    name = "adapter snapshots preserve core order scores spans and isolation",
    run = function()
      local source = update()
      local snapshot = adapters.snapshot(source)
      assert.same("first", snapshot.items[1].id)
      assert.same({ 8, 10 }, snapshot.items[1].match.spans[2])
      source.items[1].label = "mutated"
      assert.same("Desktop/Library/", snapshot.items[1].label)
    end,
  },
  {
    name = "adapter snapshots reject duplicate identities scores and invalid spans",
    run = function()
      assert.raises("item identities must be unique", function()
        local value = update()
        value.items[2].id = "first"
        adapters.snapshot(value)
      end)
      assert.raises("scores must be strictly descending", function()
        local value = update()
        value.items[2].match.score = 3
        adapters.snapshot(value)
      end)
      assert.raises("spans%[1%] is invalid", function()
        local value = update()
        value.items[1].match.spans[1][2] = 99
        adapters.snapshot(value)
      end)
    end,
  },
  {
    name = "adapter finalizer publishes exactly one terminal snapshot",
    run = function()
      local observed = {}
      local consume = adapters.finalizer(function(snapshot)
        observed[#observed + 1] = snapshot
      end)
      consume(update({ done = false }))
      consume(update())
      consume(update())
      assert.same(1, #observed)
      assert.truthy(observed[1].done)
    end,
  },
  {
    name = "adapter token ranges preserve escaped spaces and replace suffixes",
    run = function()
      local line = "open My\\ Documents/fiZZ tail"
      local range = adapters.token_range(line, 21)
      assert.same({ start_byte = 5, end_byte = 23, query = "My\\ Documents/fi" }, range)

      local request = adapters.text_request({
        line = line,
        cursor_byte = 21,
        start_byte = 5,
        end_byte = 23,
      }, {
        cwd = "/tmp",
      })
      assert.same("path", request.category)
      assert.same("filesystem", request.provider)
      assert.same("My Documents/fi", request.query)
      assert.same({ start_byte = 5, end_byte = 23 }, request.replacement)

      local quoted_line = "s = '~/De'"
      local quoted = adapters.token_range(quoted_line, #quoted_line - 1)
      assert.same({ start_byte = 5, end_byte = 9, query = "~/De" }, quoted)
      local quoted_request = adapters.text_request({
        line = quoted_line,
        cursor_byte = #quoted_line - 1,
      })
      assert.same("~/De", quoted_request.query)
      assert.same({ start_byte = 5, end_byte = 9 }, quoted_request.replacement)

      local double_quoted_line = 'local p = "~/Doc/Lib"'
      local double_quoted = adapters.token_range(double_quoted_line, #double_quoted_line - 1)
      assert.same({ start_byte = 11, end_byte = 20, query = "~/Doc/Lib" }, double_quoted)
      assert.raises("single%-line valid UTF%-8", function()
        adapters.token_range("first\nsecond", 5)
      end)
      assert.raises("single%-line valid UTF%-8", function()
        adapters.text_request({ line = "first\rsecond", cursor_byte = 5 })
      end)
    end,
  },
  {
    name = "adapter path tokens decode quotes and symmetrically encode insertion text",
    run = function()
      local quoted_line = 's = "~/My Documents/fiZZ" tail'
      local cursor_byte = string.find(quoted_line, "fiZZ", 1, true) + 1
      local closing_quote = string.find(quoted_line, '" tail', 1, true)
      local request, token = adapters.text_request({
        line = quoted_line,
        cursor_byte = cursor_byte,
      })
      assert.same("~/My Documents/fi", request.query)
      assert.same("~/My Documents/fi", token.raw_query)
      assert.same({ start_byte = 5, end_byte = closing_quote - 1 }, request.replacement)
      assert.same("~/My Documents/file.txt", adapters.encode_path_token(token, "~/My Documents/file.txt"))
      assert.same('~/My Documents/O\\"Reilly.txt', adapters.encode_path_token(token, '~/My Documents/O"Reilly.txt'))

      local apostrophe_line = 's = "/tmp/O\'ReZZ" tail'
      local apostrophe_cursor = string.find(apostrophe_line, "ReZZ", 1, true) + 1
      local apostrophe_request = adapters.text_request({
        line = apostrophe_line,
        cursor_byte = apostrophe_cursor,
      })
      assert.same("/tmp/O'Re", apostrophe_request.query)
      assert.same(5, apostrophe_request.replacement.start_byte)

      local escaped_line = "open My\\ Documents/fiZZ tail"
      local escaped_request, escaped_token = adapters.text_request({
        line = escaped_line,
        cursor_byte = 21,
      })
      assert.same("My Documents/fi", escaped_request.query)
      assert.same("My\\ Documents/fi", escaped_token.raw_query)
      assert.same("My\\ Documents/file.txt", adapters.encode_path_token(escaped_token, "My Documents/file.txt"))

      local plain_request, plain_token = adapters.text_request({
        line = "open My/fi",
        cursor_byte = 10,
      })
      assert.same("My/fi", plain_request.query)
      assert.same("My\\ Documents/file.txt", adapters.encode_path_token(plain_token, "My Documents/file.txt"))
    end,
  },
  {
    name = "adapter LSP items retain insertion ranges rank metadata and highlights",
    run = function()
      local items = adapters.lsp_items(update(), {
        line = 3,
        start_byte = 2,
        end_byte = 7,
      }, {
        filter_text = "de/li",
        source_text = "x de/li",
        cursor_byte = 7,
      })
      assert.same("0000000001", items[1].sortText)
      assert.same("de/li", items[1].filterText)
      assert.same(19, items[1].kind)
      assert.same("Desktop/Library/", items[1].textEdit.newText)
      assert.same({ line = 3, character = 2 }, items[1].textEdit.range.start)
      assert.same({ line = 3, character = 7 }, items[1].textEdit.range["end"])
      assert.same(2048, items[1].score_offset)
      assert.same(1024, items[2].score_offset)
      assert.same({ 8, 10 }, items[1].data.partial_completion.spans[2])
      assert.same("/tmp/Desktop/Library", items[1].data.partial_completion.provider_data.path)
      assert.same(1, items[1].data.partial_completion.ordinal)
      assert.truthy(adapters.same_lsp_context(items[1], { source_text = "x de/li", cursor_byte = 7 }))
      assert.falsy(adapters.same_lsp_context(items[1], { source_text = "x de/lix", cursor_byte = 8 }))
      assert.truthy(adapters.applied_lsp_context(items[1], {
        source_text = "x Desktop/Library/",
        cursor_byte = 2 + #"Desktop/Library/",
      }))

      local multiline = update()
      multiline.items[1].insert_text = "Desktop\nLibrary"
      assert.raises("must not contain CR or LF", function()
        adapters.lsp_items(multiline, { line = 0, start_byte = 0, end_byte = 1 })
      end)
      assert.raises("insertion text", function()
        adapters.lsp_items(update(), { line = 0, start_byte = 0, end_byte = 1 }, {
          insert_text = function()
            return "unsafe\ntext"
          end,
        })
      end)
    end,
  },
}
