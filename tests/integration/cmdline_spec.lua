local assert = require("tests.helpers.assertions")
local completion = require("partial_completion")

local function with_root(callback)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  local ok, err = xpcall(function()
    callback(root)
  end, debug.traceback)
  vim.fn.delete(root, "rf")
  if not ok then
    error(err, 0)
  end
end

local function complete(source_text, options, cursor_byte)
  local updates = {}
  options = options or {}
  options.context = options.context or { live = false }
  local handle, context = completion.complete_cmdline(source_text, cursor_byte or #source_text, function(update)
    updates[#updates + 1] = update
  end, options)
  assert.truthy(
    vim.wait(3000, function()
      return updates[#updates] and updates[#updates].done
    end, 1),
    "command-line completion timed out: " .. source_text
  )
  local final = updates[#updates]
  handle:cancel()
  return final, context
end

local function find_item(items, label)
  for _, item in ipairs(items) do
    if item.label == label then
      return item
    end
  end
  return nil
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end

local function has_context(contexts, predicate)
  for _, context in ipairs(contexts) do
    if predicate(context) then
      return true
    end
  end
  return false
end

return {
  {
    name = "Neovim provider normalizes command option help function variable mapping and generic categories",
    run = function()
      vim.api.nvim_create_user_command("PhaseFourCommand", function() end, {})
      vim.api.nvim_exec2("function! PhaseFourFunction() abort\nendfunction", {})
      vim.g.PhaseFourVariable = 1
      vim.keymap.set("n", "<C-W><C-D>", "<Nop>")

      local command, command_context = complete("pfc")
      assert.same("command", command_context.category)
      assert.truthy(find_item(command.items, "PhaseFourCommand"))

      local option, option_context = complete("set wildm")
      assert.same("option", option_context.category)
      assert.truthy(find_item(option.items, "wildmenu"))
      assert.truthy(find_item(option.items, "wildmode"))

      local help, help_context = complete("help help-t")
      assert.same("help", help_context.category)
      assert.truthy(find_item(help.items, "help-tags"))

      local fn_items, function_context = complete("call pff")
      assert.same("function", function_context.category)
      assert.truthy(find_item(fn_items.items, "PhaseFourFunction()"))

      local variable, variable_context = complete("unlet g:Phase")
      assert.same("variable", variable_context.category)
      assert.truthy(find_item(variable.items, "g:PhaseFourVariable"))

      local mapping, mapping_context = complete("map c-w")
      assert.same("mapping", mapping_context.category)
      assert.truthy(find_item(mapping.items, "<C-W>"))

      vim.keymap.del("n", "<C-W><C-D>")
      vim.g.PhaseFourVariable = nil
      vim.api.nvim_exec2("delfunction PhaseFourFunction", {})
      vim.api.nvim_del_user_command("PhaseFourCommand")
    end,
  },
  {
    name = "buffer colorscheme shell and unsupported contexts remain safe",
    run = function()
      with_root(function(root)
        local buffer = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(buffer, root .. "/Phase Four Buffer.txt")
        local buffer_result, buffer_context = complete("buffer Phase-Fo-Bu")
        assert.same("buffer", buffer_context.category)
        local buffer_item = find_item(buffer_result.items, root .. "/Phase Four Buffer.txt")
        assert.truthy(buffer_item)
        assert.truthy(string.find(buffer_item.insert_text, [[Phase\ Four]], 1, true))

        vim.fn.mkdir(root .. "/colors", "p")
        vim.fn.writefile({ "highlight clear" }, root .. "/colors/phase-four-color.vim")
        vim.opt.runtimepath:prepend(root)
        local color, color_context = complete("colorscheme phase")
        assert.same("generic", color_context.category)
        assert.truthy(find_item(color.items, "phase-four-color"))
        vim.opt.runtimepath:remove(root)

        local shell, shell_context = complete("!sh")
        assert.same("shellcmd", shell_context.completion_type)
        assert.same("sh", shell_context.query)
        assert.truthy(find_item(shell.items, "sh"))

        local unsupported, unsupported_context = complete("normal! gg")
        assert.same("generic", unsupported_context.category)
        assert.same({}, unsupported.items)
        assert.same(nil, unsupported.error)
        vim.api.nvim_buf_delete(buffer, { force = true })
      end)
    end,
  },
  {
    name = "filesystem routing preserves escaping token suffixes and directory-only contexts",
    run = function()
      with_root(function(root)
        vim.fn.mkdir(root .. "/My Documents", "p")
        vim.fn.mkdir(root .. "/Desk", "p")
        vim.fn.mkdir(root .. "/Desktop/a", "p")
        vim.fn.mkdir(root .. "/Directory", "p")
        vim.fn.mkdir(root .. "/docs/long-child", "p")
        vim.fn.mkdir(root .. "/dotfiles/b", "p")
        vim.fn.writefile({ "fixture" }, root .. "/Desk/task.lua")
        vim.fn.writefile({ "fixture" }, root .. "/Directory/child.txt")
        vim.fn.writefile({ "fixture" }, root .. "/Directory.txt")
        completion.setup({ filesystem = { case_sensitive = false, cache = { ttl_ms = 0 } } })
        local options = { cwd = root, case_mode = "insensitive", context = { live = false } }

        local escaped, escaped_context = complete([[edit My\ Do]], options)
        assert.same("My Do", escaped_context.query)
        local escaped_item = find_item(escaped.items, "My Documents/")
        assert.truthy(escaped_item)
        assert.same([[My\ Documents/]], escaped_item.insert_text)

        vim.fn.mkdir(root .. "/O'Reilly", "p")
        vim.fn.writefile({ "fixture" }, root .. "/bad|name")
        local apostrophe, apostrophe_context = complete("edit O'Re", options)
        assert.same("O'Re", apostrophe_context.query)
        local apostrophe_item = find_item(apostrophe.items, "O'Reilly/")
        assert.truthy(apostrophe_item)
        assert.same([[O\'Reilly/]], apostrophe_item.insert_text)

        local separator = complete("edit bad", options)
        local separator_item = find_item(separator.items, "bad|name")
        assert.truthy(separator_item)
        assert.same([[bad\|name]], separator_item.insert_text)

        local directories, directory_context = complete("cd Di", options)
        assert.same("dir_in_path", directory_context.completion_type)
        assert.same("path", directory_context.category)
        assert.truthy(find_item(directories.items, "Directory/"))
        assert.falsy(find_item(directories.items, "Directory.txt"))

        local children, children_context = complete("edit d/", options)
        assert.same("d/", children_context.query)
        assert.truthy(find_item(children.items, "Desk/task.lua"))
        assert.truthy(find_item(children.items, "Directory/child.txt"))
        assert.falsy(find_item(children.items, "Desktop/./"))
        assert.falsy(find_item(children.items, "Desktop/../"))
        local labels = {}
        for _, item in ipairs(children.items) do
          labels[#labels + 1] = item.label
        end
        assert.same({
          "Desktop/a/",
          "dotfiles/b/",
          "Desk/task.lua",
          "docs/long-child/",
          "Directory/child.txt",
        }, labels)

        local source = [[edit My\ Do.txt | keepalt]]
        local midline, midline_context = complete(source, options, 11)
        assert.same({ start_byte = 5, end_byte = 15 }, midline_context.replacement)
        assert.same("My Do", midline_context.query)
        assert.truthy(find_item(midline.items, "My Documents/"))
      end)
    end,
  },
  {
    name = "custom customlist and Lua callbacks remain authoritative",
    run = function()
      local definitions = [[
function! PhaseFourCustom(A, L, P) abort
  let g:phase_four_custom_call = [a:A, a:L, a:P]
  return "PhaseFourCandidate\nOther"
endfunction
function! PhaseFourCustomList(A, L, P) abort
  let g:phase_four_customlist_call = [a:A, a:L, a:P]
  return ["PhaseFourCandidate", "Other"]
endfunction
command! -nargs=* -complete=custom,PhaseFourCustom PhaseFourCustomCmd echo
command! -nargs=* -complete=customlist,PhaseFourCustomList PhaseFourCustomListCmd echo
]]
      vim.api.nvim_exec2(definitions, {})
      local custom_source = "PhaseFourCustomCmd Phase"
      local custom, custom_context = complete(custom_source)
      assert.same("custom,PhaseFourCustom", custom_context.completion_type)
      assert.same({ start_byte = 19, end_byte = 24 }, custom_context.replacement)
      assert.truthy(find_item(custom.items, "PhaseFourCandidate"))
      assert.same({ "Phase", custom_source, #custom_source }, vim.g.phase_four_custom_call)

      local list_source = "PhaseFourCustomListCmd Phase"
      local customlist, customlist_context = complete(list_source)
      assert.same("customlist,PhaseFourCustomList", customlist_context.completion_type)
      assert.truthy(find_item(customlist.items, "PhaseFourCandidate"))
      assert.same({ "Phase", list_source, #list_source }, vim.g.phase_four_customlist_call)

      local lua_call
      vim.api.nvim_create_user_command("PhaseFourLuaCustom", function() end, {
        nargs = "*",
        complete = function(arglead, cmdline_text, cursorpos)
          lua_call = { arglead, cmdline_text, cursorpos }
          return { "LuaCandidate", "Other" }
        end,
      })
      local lua_source = "PhaseFourLuaCustom Lua"
      local lua_custom, lua_context = complete(lua_source)
      assert.same("", lua_context.completion_type)
      assert.truthy(find_item(lua_custom.items, "LuaCandidate"))
      assert.same({ "Lua", lua_source, #lua_source }, lua_call)

      vim.api.nvim_del_user_command("PhaseFourLuaCustom")
      vim.api.nvim_exec2(
        [[delcommand PhaseFourCustomCmd
delcommand PhaseFourCustomListCmd
delfunction PhaseFourCustom
delfunction PhaseFourCustomList]],
        {}
      )
      vim.g.phase_four_custom_call = nil
      vim.g.phase_four_customlist_call = nil
    end,
  },
  {
    name = "file_in_path and dir_in_path traverse path and cdpath roots",
    run = function()
      with_root(function(root)
        local path_root = root .. "/include"
        local cd_root = root .. "/locations"
        vim.fn.mkdir(path_root .. "/Desktop", "p")
        vim.fn.mkdir(cd_root .. "/Deploy/Logs", "p")
        vim.fn.writefile({ "fixture" }, path_root .. "/Desktop/license.txt")
        local old_path = vim.o.path
        local old_cdpath = vim.o.cdpath
        local ok, err = xpcall(function()
          vim.opt.path = { path_root }
          vim.opt.cdpath = { cd_root }
          local options = { cwd = root, case_mode = "insensitive", context = { live = false } }

          local files, file_context = complete("find de/li", options)
          assert.same("file_in_path", file_context.completion_type)
          assert.truthy(find_item(files.items, "Desktop/license.txt"))

          local directories, directory_context = complete("cd de/lo", options)
          assert.same("dir_in_path", directory_context.completion_type)
          assert.truthy(find_item(directories.items, "Deploy/Logs/"))

          vim.fn.writefile({ "must not leak" }, root .. "/fallback-only.txt")
          vim.opt.path = { root .. "/missing/**" }
          local unsupported = complete("find fa", options)
          assert.same(0, #unsupported.items)
        end, debug.traceback)
        vim.o.path = old_path
        vim.o.cdpath = old_cdpath
        if not ok then
          error(err, 0)
        end
      end)
    end,
  },
  {
    name = "controller discards late provider updates after replacement and cancellation",
    run = function()
      local callbacks = {}
      local handles = {}
      local observed = {}
      local controller = require("partial_completion.cmdline").new_controller({
        complete = function(_, callback)
          callbacks[#callbacks + 1] = callback
          local handle = { cancelled = false }
          function handle:cancel()
            self.cancelled = true
          end
          handles[#handles + 1] = handle
          return handle
        end,
        on_update = function(update)
          observed[#observed + 1] = update
        end,
      })
      local first = completion.analyze_cmdline("set wild", 8, { live = false })
      local second = completion.analyze_cmdline("set wildm", 9, { live = false })
      controller:request(first, 1)
      controller:request(second, 1)
      assert.truthy(handles[1].cancelled)
      callbacks[1]({ items = { "late" } })
      callbacks[2]({ items = { "current" } })
      assert.same(1, #observed)
      controller:stop()
      callbacks[2]({ items = { "cancelled" } })
      assert.same(1, #observed)
    end,
  },
  {
    name = "live command-line events preserve edits history acceptance and cmdwin safety",
    run = function()
      local cmdline = require("partial_completion.cmdline")
      local contexts = {}
      local handles = {}
      local accepted
      local accepted_live
      local accept_error
      local cmdwin_enters = 0
      local controller = cmdline.new_controller({
        complete = function(_, callback)
          local handle = { cancelled = false }
          function handle:cancel()
            self.cancelled = true
          end
          handles[#handles + 1] = handle
          callback({
            items = {
              { id = "wildmenu", source = "test", label = "wildmenu", insert_text = "wildmenu" },
            },
            done = true,
          })
          return handle
        end,
        on_context = function(context)
          contexts[#contexts + 1] = vim.deepcopy(context)
        end,
      })

      local group = vim.api.nvim_create_augroup("PartialCompletionCmdlineIntegration", { clear = true })
      vim.api.nvim_create_autocmd("CmdwinEnter", {
        group = group,
        pattern = ":",
        callback = function()
          cmdwin_enters = cmdwin_enters + 1
        end,
      })
      vim.keymap.set("c", "<F6>", function()
        accepted, accept_error = controller:accept({ id = "wildmenu", source = "test", insert_text = "FORGED" })
        accepted_live = {
          source_text = vim.fn.getcmdline(),
          cursor_byte = vim.fn.getcmdpos() - 1,
        }
        return ""
      end, { expr = true })

      local ok, err = xpcall(function()
        controller:start()
        feed(":set wildm | echo<Left><Left><Left><Left><Left><Left><Left><F6><Esc>")
        assert.same(nil, accept_error)
        assert.same("accepted", accepted.status)
        assert.same("set wildmenu | echo", accepted_live.source_text)
        assert.same(12, accepted_live.cursor_byte)
        assert.truthy(has_context(contexts, function(context)
          return context.reason == "CursorMovedC" and context.cursor_byte == 9
        end))
        assert.same(nil, controller.active_level)

        contexts = {}
        feed(":set wildm<BS><Esc>")
        assert.truthy(has_context(contexts, function(context)
          return context.reason == "CmdlineChanged" and context.source_text == "set wild"
        end))

        vim.fn.histadd("cmd", "set number")
        contexts = {}
        feed(":<Up><Esc>")
        assert.truthy(has_context(contexts, function(context)
          return context.source_text == "set number"
        end))
        assert.same("set number", vim.fn.histget("cmd", -1))

        controller:request(completion.analyze_cmdline("set wildm", 9, { live = false }), 1)
        local first_cmdwin_handle = #handles
        feed("q::quit<CR>")
        assert.same(1, cmdwin_enters)
        assert.same("", vim.fn.getcmdwintype())
        assert.same(nil, controller.active_level)
        for index = first_cmdwin_handle, #handles do
          assert.truthy(handles[index].cancelled, "cmdwin request was not cancelled")
        end
      end, debug.traceback)

      controller:stop()
      pcall(vim.keymap.del, "c", "<F6>")
      pcall(vim.api.nvim_del_augroup_by_id, group)
      vim.fn.histdel("cmd", "^set number$")
      if not ok then
        error(err, 0)
      end
    end,
  },
}
