local config = require("partial_completion.config")
local cmdline = require("partial_completion.cmdline")
local Engine = require("partial_completion.engine")
local Providers = require("partial_completion.providers")
local filesystem = require("partial_completion.providers.filesystem")
local logger = require("partial_completion.logger")
local neovim = require("partial_completion.providers.neovim")
local session = require("partial_completion.session")

local M = {
  api_version = 1,
}

local providers = Providers.new()
local active_config = config.resolve({})
logger.configure(active_config.debug)
filesystem.configure(active_config.filesystem)
providers:register("filesystem", filesystem)
providers:register("neovim", neovim)
local engine = Engine.new(active_config, providers)
local native_adapter
local sync_native
local last_config_error

function M.setup(options)
  local ok, resolved = pcall(config.resolve, options)
  if not ok then
    last_config_error = tostring(resolved)
    logger.debug("configuration_rejected", {})
    error(resolved, 2)
  end
  last_config_error = nil
  local native_changed = not vim.deep_equal(active_config.native, resolved.native)
  local filesystem_changed = not vim.deep_equal(active_config.filesystem, resolved.filesystem)
  active_config = resolved
  logger.configure(active_config.debug)
  if filesystem_changed then
    filesystem.configure(active_config.filesystem)
  end
  engine:set_config(active_config)
  if native_changed then
    sync_native()
  end
  return M
end

function M.debug_records()
  return logger.records()
end

function M.clear_debug_records()
  logger.clear()
end

function M._health_snapshot()
  return {
    config = config.copy(active_config),
    last_config_error = last_config_error,
    native_enabled = native_adapter ~= nil,
  }
end

function M.register_provider(name, provider, options)
  providers:register(name, provider, options)
end

function M.complete(request, callback)
  return engine:complete(request, callback)
end

function M.new_session(options)
  options = options or {}
  return session.new({
    complete = options.complete or function(request, callback)
      return engine:complete(request, callback)
    end,
    on_change = options.on_change,
    on_close = options.on_close,
    on_error = options.on_error,
    select_first = options.select_first,
  })
end

function M.analyze_cmdline(source_text, cursor_byte, options)
  return cmdline.analyze(source_text, cursor_byte, options)
end

function M.complete_cmdline(source_text, cursor_byte, callback, options)
  if type(callback) ~= "function" then
    error("command-line completion callback must be a function", 2)
  end
  options = options or {}
  local context = cmdline.analyze(source_text, cursor_byte, options.context)
  local handle = engine:complete(neovim.request(context, options), callback)
  return handle, context
end

function M.new_cmdline_controller(options)
  options = options or {}
  local request_options = options.request or {}
  return cmdline.new_controller({
    complete = function(context, callback)
      return engine:complete(neovim.request(context, request_options), callback)
    end,
    on_update = options.on_update,
    on_state = options.on_state,
    on_context = options.on_context,
    on_error = options.on_error,
  })
end

local function start_native(native_config)
  if native_adapter ~= nil then
    native_adapter:stop()
  end
  local native = require("partial_completion.adapters.native")
  native_adapter = native.new({
    config = native_config,
    new_controller = M.new_cmdline_controller,
    on_error = function(err)
      vim.schedule(function()
        vim.notify("partial-completion native UI: " .. tostring(err), vim.log.levels.ERROR)
      end)
    end,
  })
  native_adapter:start()
  return native_adapter
end

sync_native = function()
  if native_adapter ~= nil then
    native_adapter:stop()
    native_adapter = nil
  end
  if active_config.native.enabled then
    start_native(active_config.native)
  end
end

function M.enable_native(options)
  options = options or {}
  if type(options) ~= "table" then
    error("native options must be a table", 2)
  end
  local merged = vim.tbl_deep_extend("force", config.copy(active_config.native), options, { enabled = true })
  local native_config = config.resolve({ native = merged }).native
  return start_native(native_config)
end

function M.disable_native()
  if native_adapter ~= nil then
    native_adapter:stop()
    native_adapter = nil
  end
end

function M.native_state()
  return native_adapter and native_adapter:state() or nil
end

function M.native_enabled()
  return native_adapter ~= nil
end

function M.native_visible()
  return native_adapter ~= nil and native_adapter:is_visible()
end

return M
