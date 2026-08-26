local adapter_name = assert(vim.env.PARTIAL_COMPLETION_SMOKE_ADAPTER, "adapter name is required")
local dependencies = assert(vim.env.PARTIAL_COMPLETION_DEPS_DIR, "dependency directory is required")
local fixture = assert(vim.env.PARTIAL_COMPLETION_SMOKE_FIXTURE, "fixture directory is required")
local output = assert(vim.env.PARTIAL_COMPLETION_SMOKE_OUTPUT, "smoke output is required")
local expected_line = adapter_name == "nvim_cmp" and 's = "My Documents/file.txt" tail'
  or "Desktop/Library/demo.txt tail"
local blink_query = "edit ~/d/l/u"
local expected_blink_line = "edit ~/Documents/lc0/uci_nodes1_proxy.py"
local target_path = vim.uv.fs_realpath(fixture .. "/Desktop/Library/demo.txt")
  or (fixture .. "/Desktop/Library/demo.txt")
local original_notify = vim.notify
local state = {
  adapter = adapter_name,
  accepted = false,
  exited = false,
  menu_shown = false,
  notifications = {},
  async_errors = {},
}

local function publish()
  vim.fn.writefile({ vim.json.encode(state) }, output)
end

vim.notify = function(message, level, options)
  if (level or vim.log.levels.INFO) >= vim.log.levels.WARN then
    state.notifications[#state.notifications + 1] = tostring(message)
    publish()
  end
  return original_notify(message, level, options)
end

local original_schedule = vim.schedule
local original_defer_fn = vim.defer_fn
local function guarded(callback)
  return function(...)
    local arguments = { ... }
    local ok, err = xpcall(function()
      callback(unpack(arguments))
    end, debug.traceback)
    if not ok then
      state.async_errors[#state.async_errors + 1] = tostring(err)
      publish()
    end
  end
end

vim.schedule = function(callback)
  return original_schedule(guarded(callback))
end

vim.defer_fn = function(callback, timeout)
  return original_defer_fn(guarded(callback), timeout)
end

local function add_dependency(name)
  local path = dependencies .. "/" .. name
  assert(vim.fn.isdirectory(path) == 1, "missing adapter dependency: " .. path)
  vim.opt.runtimepath:prepend(path)
end

local function observe_line()
  local line = vim.api.nvim_get_current_line()
  if line == expected_line then
    state.accepted = true
    state.accepted_text = line
    publish()
  end
end

local function prepare_insert_buffer()
  local line = 's = "My Documents/fiZZ" tail'
  local cursor_byte = string.find(line, "fiZZ", 1, true) + 1
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
  vim.api.nvim_win_set_cursor(0, { 1, cursor_byte })
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
    callback = observe_line,
  })
end

local function telescope_smoke()
  add_dependency("plenary.nvim")
  add_dependency("telescope.nvim")
  require("telescope").setup({
    defaults = {
      initial_mode = "insert",
      layout_strategy = "horizontal",
      sorting_strategy = "ascending",
    },
  })
  require("telescope").load_extension("partial_completion")
  local function observe_path()
    if vim.api.nvim_buf_get_name(0) == target_path then
      state.accepted = true
      state.accepted_text = target_path
      publish()
    end
  end
  vim.api.nvim_create_autocmd({ "BufEnter", "BufReadPost", "BufWinEnter" }, {
    callback = function()
      vim.schedule(observe_path)
    end,
  })
  local picker, err = require("partial_completion.adapters.telescope").files({
    cwd = fixture,
    default_text = "de/li/de",
    attach_mappings = function(_, map)
      map("i", "<Tab>", require("telescope.actions").select_default)
      return true
    end,
  })
  assert(picker ~= nil, err)
  state.prompt_buffer = picker.prompt_bufnr
  state.menu_shown = true
  publish()
end

local function blink_smoke()
  add_dependency("blink.cmp")
  require("blink.cmp").setup({
    fuzzy = { implementation = "lua" },
    keymap = {
      preset = "none",
      ["<Tab>"] = { "select_and_accept" },
    },
    completion = {
      menu = {
        auto_show = true,
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
      sources = { "partial_completion" },
      completion = {
        list = { selection = { preselect = false, auto_insert = true } },
        menu = { auto_show = true },
      },
      keymap = {
        preset = "none",
        ["<Tab>"] = { "select_and_accept" },
      },
    },
  })
  vim.api.nvim_create_autocmd("CmdlineChanged", {
    pattern = ":",
    callback = function()
      local line = vim.fn.getcmdline()
      if line == expected_blink_line then
        state.accepted = true
        state.accepted_text = line
        publish()
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    pattern = "BlinkCmpShow",
    callback = function()
      local menu = require("blink.cmp.completion.windows.menu")
      if menu.context == nil or menu.context.mode ~= "cmdline" then
        return
      end
      state.menu_shown = require("blink.cmp").is_menu_visible()
      state.first_label = menu.items[1] and menu.items[1].label or nil
      state.core_spans = menu.items[1]
          and menu.items[1].data
          and menu.items[1].data.partial_completion
          and menu.items[1].data.partial_completion.spans
        or nil
      local match_spans = {}
      for _, column in ipairs(menu.renderer.columns or {}) do
        for _, highlight in ipairs(column:get_line_highlights(1)) do
          if highlight.group == "BlinkCmpLabelMatch" then
            match_spans[#match_spans + 1] = { highlight[1], highlight[2] }
          end
        end
      end
      state.highlight_spans = match_spans
      publish()
    end,
  })
  vim.defer_fn(function()
    local keys = vim.api.nvim_replace_termcodes(":" .. blink_query, true, false, true)
    vim.api.nvim_feedkeys(keys, "nt", false)
  end, 20)
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
    mapping = {
      ["<Tab>"] = cmp.mapping.confirm({ select = true }),
    },
    preselect = cmp.PreselectMode.None,
    sources = {
      { name = "partial_completion" },
    },
  })
  cmp.event:on("menu_opened", function()
    state.menu_shown = cmp.visible()
    publish()
  end)
  prepare_insert_buffer()
  vim.cmd.startinsert()
  vim.defer_fn(function()
    cmp.complete()
  end, 20)
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  once = true,
  callback = function()
    state.exited = true
    publish()
  end,
})

publish()
vim.schedule(function()
  if adapter_name == "telescope" then
    telescope_smoke()
  elseif adapter_name == "blink" then
    blink_smoke()
  elseif adapter_name == "nvim_cmp" then
    nvim_cmp_smoke()
  else
    error("unknown adapter: " .. adapter_name)
  end
end)
