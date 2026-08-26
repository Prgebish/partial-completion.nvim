local adapter_name = assert(arg[1], "adapter name is required")
local root = vim.fn.getcwd()
local dependencies = vim.env.PARTIAL_COMPLETION_DEPS_DIR or (root .. "/deps")
local fixture = vim.fn.tempname()
local original_notify = vim.notify
local notifications = {}

vim.notify = function(message, level, options)
  if (level or vim.log.levels.INFO) >= vim.log.levels.WARN then
    notifications[#notifications + 1] = tostring(message)
  end
  return original_notify(message, level, options)
end

local function add_dependency(name)
  local path = dependencies .. "/" .. name
  assert(vim.fn.isdirectory(path) == 1, "missing adapter dependency: " .. path)
  vim.opt.runtimepath:prepend(path)
end

local function wait_for(predicate, message)
  assert(vim.wait(5000, predicate, 5), message)
end

local function blink_context(id, mode, line, start_byte, cursor_byte)
  cursor_byte = cursor_byte or #line
  return {
    mode = mode,
    id = id,
    bufnr = vim.api.nvim_get_current_buf(),
    cursor = { 1, cursor_byte },
    line = line,
    bounds = {
      line = line,
      line_number = 1,
      start_col = start_byte + 1,
      length = #line - start_byte,
    },
    trigger = {
      initial_kind = "manual",
      kind = "manual",
    },
    providers = { "partial_completion" },
    timestamp = vim.uv.now(),
  }
end

local function telescope_smoke()
  add_dependency("plenary.nvim")
  add_dependency("telescope.nvim")
  local telescope = require("telescope")
  telescope.setup({
    defaults = {
      layout_strategy = "horizontal",
      sorting_strategy = "ascending",
    },
  })
  telescope.load_extension("partial_completion")
  local extension = telescope.extensions.partial_completion
  assert(type(extension.files) == "function")
  assert(type(extension.commands) == "function")
  local telescope_adapter = require("partial_completion.adapters.telescope")

  local file_picker = assert(telescope_adapter.files({
    cwd = fixture,
    default_text = "de/li/de",
  }))
  local state = require("telescope.state")
  wait_for(function()
    return #state.get_existing_prompt_bufnrs() == 1
  end, "Telescope file picker did not create a prompt")
  local prompt_buffers = state.get_existing_prompt_bufnrs()
  wait_for(function()
    return type(file_picker.manager) == "table" and file_picker.manager:num_results() > 0
  end, "Telescope file picker produced no results")
  local file_entry = file_picker.manager:get_entry(1)
  assert(file_entry.value.label == "Desktop/Library/demo.txt")
  assert(file_entry.path == fixture .. "/Desktop/Library/demo.txt")
  assert(file_picker.previewer ~= nil, "Telescope file previewer was not attached")
  local display, highlights = file_entry:display(file_picker)
  assert(display == file_entry.value.label)
  assert(#highlights > 0, "Telescope entry omitted core highlight spans")

  assert(#prompt_buffers == 1, "Telescope file picker did not own one prompt")
  require("telescope.actions").close(prompt_buffers[1])
  wait_for(function()
    return #state.get_existing_prompt_bufnrs() == 0
  end, "Telescope file picker did not close")

  local command_picker = assert(telescope_adapter.commands({
    default_text = "part",
  }))
  wait_for(function()
    return #state.get_existing_prompt_bufnrs() == 1
  end, "Telescope command picker did not create a prompt")
  prompt_buffers = state.get_existing_prompt_bufnrs()
  wait_for(function()
    return type(command_picker.manager) == "table" and command_picker.manager:num_results() > 0
  end, "Telescope command picker produced no results")
  local found_command = false
  for entry in command_picker.manager:iter() do
    if entry.value.label == "PartialCompletionEnable" then
      found_command = true
      break
    end
  end
  assert(found_command, "Telescope command picker omitted partial completion commands")
  assert(#prompt_buffers == 1, "Telescope command picker did not own one prompt")
  require("telescope.actions").close(prompt_buffers[1])
  wait_for(function()
    return #state.get_existing_prompt_bufnrs() == 0
  end, "Telescope command picker did not close")
end

local function blink_smoke()
  add_dependency("blink.cmp")
  require("blink.cmp").setup({
    fuzzy = { implementation = "lua" },
    keymap = { preset = "none" },
    completion = {
      menu = {
        auto_show = false,
      },
    },
    sources = {
      default = { "partial_completion" },
      providers = {
        partial_completion = {
          name = "Partial Completion",
          module = "partial_completion.adapters.blink",
          async = true,
          opts = {
            cwd = fixture,
            request = { home = fixture },
          },
        },
      },
    },
    cmdline = {
      keymap = { preset = "none" },
      sources = { "partial_completion" },
    },
  })

  local sources = require("blink.cmp.sources.lib")
  local provider = sources.get_provider_by_id("partial_completion")
  assert(provider.name == "Partial Completion")
  local insert_items = {}
  provider:get_completions(blink_context(1, "default", "de/li/de", 0), function(items)
    if #items > 0 then
      insert_items = items
    end
  end)
  wait_for(function()
    return #insert_items >= 2
  end, "Blink insert provider produced no results")
  assert(insert_items[1].label == "Desktop/Library/demo.txt")
  assert(insert_items[2].label == "Desktop/Library/debugger-long.txt")
  assert(insert_items[1].score_offset - insert_items[2].score_offset >= 1024)
  assert(insert_items[1].source_id == "partial_completion")
  assert(insert_items[1].textEdit.range.start.character == 0)
  assert(insert_items[1].textEdit.range["end"].character == #"de/li/de")
  assert(provider.list.is_incomplete_forward)
  assert(provider.list.is_incomplete_backward)
  local draw = require("blink.cmp.config").completion.menu.draw
  local draw_context = require("blink.cmp.completion.windows.render.context").new(draw, 1, insert_items[1], { 16, 17 })
  local highlights = draw.components.label.highlight(draw_context)
  local match_spans = {}
  for _, highlight in ipairs(highlights) do
    if highlight.group == "BlinkCmpLabelMatch" then
      match_spans[#match_spans + 1] = { highlight[1], highlight[2] }
    end
  end
  assert(vim.deep_equal(match_spans, { { 0, 2 }, { 8, 10 }, { 16, 18 } }))
  provider.list:destroy()

  local quoted_line = "s = 'My Documents/fiZZ'"
  local quoted_cursor = string.find(quoted_line, "fiZZ", 1, true) + 1
  local quoted_end = string.find(quoted_line, "'", 6, true) - 1
  local quoted_items = {}
  provider:get_completions(blink_context(2, "default", quoted_line, 5, quoted_cursor), function(items)
    if #items > 0 then
      quoted_items = items
    end
  end)
  wait_for(function()
    return #quoted_items >= 2
  end, "Blink insert provider produced no results inside a quoted string")
  assert(quoted_items[1].label == "My Documents/file.txt")
  assert(quoted_items[1].source_id == "partial_completion")
  assert(quoted_items[1].filterText == "My Documents/fi")
  assert(quoted_items[1].textEdit.newText == "My Documents/file.txt")
  assert(quoted_items[1].textEdit.range.start.character == 5)
  assert(quoted_items[1].textEdit.range["end"].character == quoted_end)
  provider.list:destroy()

  local command_line = "edit ~/d/l/u"
  local cmdline_items = {}
  provider:get_completions(blink_context(3, "cmdline", command_line, 5), function(items)
    if #items > 0 then
      cmdline_items = items
    end
  end)
  wait_for(function()
    return #cmdline_items >= 2
  end, "Blink cmdline provider produced no results")
  assert(cmdline_items[1].textEdit.range.start.character == 5)
  assert(cmdline_items[1].textEdit.range["end"].character == #command_line)
  assert(
    cmdline_items[1].label == "~/Documents/lc0/uci_nodes1_proxy.py",
    "unexpected Blink cmdline items: "
      .. vim.inspect(vim.tbl_map(function(item)
        return { label = item.label, spans = item.data.partial_completion.spans }
      end, cmdline_items))
  )
  assert(cmdline_items[1].textEdit.newText == "~/Documents/lc0/uci_nodes1_proxy.py")
  assert(vim.deep_equal(cmdline_items[1].data.partial_completion.spans, { { 0, 1 }, { 2, 3 }, { 12, 13 }, { 16, 17 } }))
  provider.list:destroy()
end

local function nvim_cmp_smoke()
  add_dependency("nvim-cmp")
  local cmp = require("cmp")
  local source_id, err = require("partial_completion.adapters.nvim_cmp").register({
    cwd = fixture,
  })
  assert(source_id ~= nil, err)
  cmp.setup({
    completion = { autocomplete = false },
    performance = { filtering_context_budget = 1000000 },
    preselect = cmp.PreselectMode.None,
    sources = {
      { name = "partial_completion" },
    },
  })

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "de/li/deZZ tail" })
  vim.api.nvim_win_set_cursor(0, { 1, #"de/li/de" })
  local context = require("cmp.context").new(nil, {
    reason = cmp.ContextReason.Manual,
  })
  local source
  for _, candidate in ipairs(cmp.get_registered_sources()) do
    if candidate.name == "partial_completion" then
      source = candidate
      break
    end
  end
  assert(source ~= nil, "nvim-cmp source was not registered")
  local completed = false
  assert(source:complete(context, function()
    completed = true
  end))
  wait_for(function()
    return completed and #source.entries >= 2
  end, "nvim-cmp source produced no entries")
  assert(source.incomplete, "nvim-cmp source did not retain isIncomplete")
  assert(source:get_position_encoding_kind() == "utf-8")
  local entry = source.entries[1]
  assert(entry.completion_item.label == "Desktop/Library/demo.txt")
  assert(entry.completion_item.textEdit.range.start.character == 0)
  assert(entry.completion_item.textEdit.range["end"].character == #"de/li/deZZ")
  assert(entry.completion_item.data.partial_completion.spans[1][1] == 0)
  assert(entry.offset == 1)
  local compare = require("partial_completion.adapters.nvim_cmp")
  assert(cmp.get_config().sorting.comparators[1] == compare.compare)
  local entries = { source.entries[1], source.entries[2] }
  cmp.config.compare.recently_used.records[entries[2].completion_item.label] = vim.uv.now()
  table.sort(entries, function(left, right)
    for _, comparator in ipairs(cmp.get_config().sorting.comparators) do
      local decision = comparator(left, right)
      if decision ~= nil then
        return decision
      end
    end
    return false
  end)
  cmp.config.compare.recently_used.records[entries[2].completion_item.label] = nil
  assert(entries[1].completion_item.label == "Desktop/Library/demo.txt")

  local function filtered_entries(line, cursor_byte)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
    vim.api.nvim_win_set_cursor(0, { 1, cursor_byte })
    local live_context = require("cmp.context").new(nil, {
      reason = cmp.ContextReason.Manual,
    })
    local finished = false
    assert(source:complete(live_context, function()
      finished = true
    end))
    wait_for(function()
      return finished
    end, "nvim-cmp source did not finish quoted path completion")
    return source:get_entries(live_context)
  end

  local quoted_line = 's = "My Documents/fiZZ" tail'
  local quoted_cursor = string.find(quoted_line, "fiZZ", 1, true) + 1
  local quoted_entries = filtered_entries(quoted_line, quoted_cursor)
  assert(#quoted_entries >= 2, "nvim-cmp host filtered every quoted path entry")
  assert(quoted_entries[1].completion_item.label == "My Documents/file.txt")
  assert(quoted_entries[1].completion_item.filterText == "My Documents/fi")
  assert(quoted_entries[1].completion_item.textEdit.newText == "My Documents/file.txt")
  assert(quoted_entries[1].offset == 6, "nvim-cmp retained the opening quote in its host input")

  local escaped_line = "open My\\ Documents/fiZZ tail"
  local escaped_entries = filtered_entries(escaped_line, 21)
  assert(#escaped_entries >= 2, "nvim-cmp host filtered every escaped path entry")
  assert(escaped_entries[1].completion_item.label == "My Documents/file.txt")
  assert(escaped_entries[1].completion_item.filterText == "My\\ Documents/fi")
  assert(escaped_entries[1].completion_item.textEdit.newText == "My\\ Documents/file.txt")
end

vim.fn.mkdir(fixture .. "/Desktop/Library", "p")
vim.fn.mkdir(fixture .. "/Desktop/Library/Unsorted", "p")
vim.fn.mkdir(fixture .. "/Documents/lc0", "p")
vim.fn.mkdir(fixture .. "/My Documents", "p")
vim.fn.writefile({ "preview" }, fixture .. "/Desktop/Library/demo.txt")
vim.fn.writefile({ "preview" }, fixture .. "/Desktop/Library/debugger-long.txt")
vim.fn.writefile({ "preview" }, fixture .. "/Documents/lc0/uci_nodes1_proxy.py")
vim.fn.writefile({ "preview" }, fixture .. "/My Documents/file.txt")
vim.fn.writefile({ "preview" }, fixture .. "/My Documents/fidelity-long.txt")
local ok, err = xpcall(function()
  if adapter_name == "telescope" then
    telescope_smoke()
  elseif adapter_name == "blink" then
    blink_smoke()
  elseif adapter_name == "nvim_cmp" then
    nvim_cmp_smoke()
  else
    error("unknown adapter: " .. adapter_name)
  end
end, debug.traceback)
vim.notify = original_notify
vim.fn.delete(fixture, "rf")
if not ok then
  error(err, 0)
end
assert(#notifications == 0, "adapter emitted warnings: " .. table.concat(notifications, "; "))
io.stdout:write("Pinned real-dependency adapter smoke passed: " .. adapter_name .. "\n")
