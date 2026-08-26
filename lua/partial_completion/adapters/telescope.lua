local adapter = require("partial_completion.adapters")
local completion = require("partial_completion")

local M = {}

local extension_config = {}

local function copy(value)
  return require("partial_completion.config").copy(value)
end

local function load_telescope()
  local modules = {}
  for name, module_name in pairs({
    actions = "telescope.actions",
    action_state = "telescope.actions.state",
    conf = "telescope.config",
    pickers = "telescope.pickers",
    sorters = "telescope.sorters",
  }) do
    local ok, module = pcall(require, module_name)
    if not ok then
      return nil, "Telescope dependency is unavailable: " .. module_name
    end
    modules[name] = module
  end
  modules.conf = modules.conf.values
  return modules
end

local function merged_options(kind, options)
  return vim.tbl_deep_extend("force", copy(extension_config[kind] or {}), options or {})
end

local function report(options, message)
  if type(options.on_error) == "function" then
    pcall(options.on_error, message)
    return
  end
  vim.schedule(function()
    vim.notify("partial-completion Telescope: " .. tostring(message), vim.log.levels.ERROR)
  end)
end

function M.available()
  return load_telescope() ~= nil
end

function M.setup(options)
  if options ~= nil and type(options) ~= "table" then
    error("Telescope extension options must be a table", 2)
  end
  extension_config = copy(options or {})
end

function M.entry(item)
  return {
    value = item,
    ordinal = item.source .. "\0" .. item.id,
    path = type(item.data) == "table" and item.data.path or nil,
    filename = type(item.data) == "table" and item.data.path or nil,
    display = function(entry)
      local highlights = {}
      for _, span in ipairs(entry.value.match.spans) do
        highlights[#highlights + 1] = {
          { span[1], span[2] },
          "TelescopeMatching",
        }
      end
      return entry.value.label, highlights
    end,
  }
end

function M.new_sorter(dependencies)
  local dependencies_error
  if dependencies == nil then
    dependencies, dependencies_error = load_telescope()
  end
  if dependencies == nil then
    error(dependencies_error, 2)
  end
  return dependencies.sorters.new({
    scoring_function = function(_, _, _, entry)
      local score = entry and entry.value and entry.value.match and entry.value.match.score
      if type(score) ~= "number" or score <= 0 then
        return -1
      end
      return 1 / score
    end,
    highlighter = function()
      return {}
    end,
  })
end

local Finder = {}
Finder.__index = Finder

function Finder:_cancel()
  local current = self.current
  self.current = nil
  if current ~= nil and current.handle ~= nil then
    pcall(current.handle.cancel, current.handle)
  end
end

function Finder:close()
  self:_cancel()
end

function Finder:_find(prompt, process_result, process_complete)
  self:_cancel()
  self.generation = self.generation + 1
  local current = {
    generation = self.generation,
    handle = nil,
    terminal = false,
  }
  self.current = current

  local function finish(snapshot)
    if self.current ~= current or current.terminal then
      return
    end
    current.terminal = true
    self.current = nil
    if snapshot.error ~= nil then
      report(self.options, snapshot.error.message or snapshot.error.code)
      process_complete()
      return
    end
    for _, item in ipairs(snapshot.items) do
      if process_result(M.entry(item)) then
        break
      end
    end
    process_complete()
  end

  local consume = adapter.finalizer(finish)
  local ok, handle = pcall(self.complete, self.request(prompt), function(update)
    if self.current ~= current or current.terminal then
      return
    end
    local consumed, err = pcall(consume, update)
    if not consumed then
      current.terminal = true
      self.current = nil
      report(self.options, err)
      process_complete()
    end
  end)
  if not ok then
    self.current = nil
    current.terminal = true
    report(self.options, handle)
    process_complete()
    return
  end
  if type(handle) ~= "table" or type(handle.cancel) ~= "function" then
    self.current = nil
    current.terminal = true
    report(self.options, "completion returned an invalid cancel handle")
    process_complete()
    return
  end
  if self.current == current and not current.terminal then
    current.handle = handle
  else
    pcall(handle.cancel, handle)
  end
end

function M.new_finder(options)
  if type(options) ~= "table" or type(options.request) ~= "function" then
    error("Telescope finder requires a request builder", 2)
  end
  local finder = setmetatable({
    complete = options.complete or completion.complete,
    request = options.request,
    options = options,
    generation = 0,
  }, Finder)
  return setmetatable(finder, {
    __index = Finder,
    __call = function(self, ...)
      return self:_find(...)
    end,
  })
end

local function request(kind, prompt, options)
  if type(options.request_builder) == "function" then
    return options.request_builder(prompt, kind)
  end
  local request_options = copy(options.request or {})
  request_options.api_version = 1
  request_options.query = prompt
  request_options.cwd = request_options.cwd or options.cwd or vim.uv.cwd() or vim.fn.getcwd()
  if kind == "files" then
    request_options.category = "path"
    request_options.provider = "filesystem"
  else
    request_options.category = "command"
    request_options.provider = "neovim"
  end
  return request_options
end

local function picker(kind, options)
  options = merged_options(kind, options)
  local dependencies, err = load_telescope()
  if dependencies == nil then
    return nil, err
  end
  local finder = M.new_finder(vim.tbl_extend("force", options, {
    request = function(prompt)
      return request(kind, prompt, options)
    end,
  }))
  local specification = {
    prompt_title = options.prompt_title
      or (kind == "files" and "Partial Completion Files" or "Partial Completion Commands"),
    finder = finder,
    sorter = options.sorter or M.new_sorter(dependencies),
  }

  if kind == "files" then
    specification.previewer = options.previewer == false and false
      or (options.previewer or dependencies.conf.file_previewer(options))
  else
    specification.previewer = options.previewer
    specification.attach_mappings = function(prompt_buffer)
      dependencies.actions.select_default:replace(function()
        local selected = dependencies.action_state.get_selected_entry()
        if selected == nil or selected.value == nil then
          return
        end
        dependencies.actions.close(prompt_buffer)
        vim.cmd.stopinsert()
        local suffix = options.command_suffix == false and "" or " "
        local keys = vim.api.nvim_replace_termcodes(":" .. selected.value.insert_text .. suffix, true, false, true)
        vim.api.nvim_feedkeys(keys, "n", false)
      end)
      return true
    end
  end

  local active = dependencies.pickers.new(options, specification)
  active:find()
  return active
end

function M.files(options)
  return picker("files", options)
end

function M.commands(options)
  return picker("commands", options)
end

return M
