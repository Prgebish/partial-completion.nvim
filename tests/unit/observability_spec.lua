local assert = require("tests.helpers.assertions")
local config = require("partial_completion.config")
local health = require("partial_completion.health")
local logger = require("partial_completion.logger")

local function logger_options(overrides)
  return vim.tbl_extend("force", {
    enabled = true,
    sensitive = false,
    max_entries = 20,
    sink = nil,
  }, overrides or {})
end

return {
  {
    name = "debug logging is disabled by default bounded and path-private",
    run = function()
      logger.clear()
      logger.configure(logger_options({ enabled = false }))
      logger.debug("silent", { path = "/private/project/secret.txt" })
      assert.same({}, logger.records())

      logger.configure(logger_options({ max_entries = 2 }))
      logger.debug("first", {
        path = "/private/project/secret.txt",
        query = "~/secret/project",
        nested = { cwd = "/private/project", count = 3 },
      })
      logger.debug("second", { count = 2 })
      logger.debug("third", { count = 3 })
      local records = logger.records()
      assert.same(2, #records)
      assert.same("second", records[1].event)
      local serialized = vim.inspect(records)
      assert.falsy(string.find(serialized, "/private/project", 1, true))
      assert.falsy(string.find(serialized, "~/secret/project", 1, true))

      logger.configure(logger_options({ sensitive = true }))
      logger.debug("sensitive", { path = "/explicit/private/path" })
      local sensitive_records = logger.records()
      assert.same("/explicit/private/path", sensitive_records[#sensitive_records].fields.path)
      logger.configure(logger_options({ sensitive = false }))
      assert.same({}, logger.records())
      logger.debug("one", {})
      logger.debug("two", {})
      logger.debug("three", {})
      logger.configure(logger_options({ max_entries = 1 }))
      assert.same({ "three" }, { logger.records()[1].event })
      logger.configure(logger_options({ enabled = false }))
    end,
  },
  {
    name = "debug sinks receive structured copies and failures stay isolated",
    run = function()
      logger.clear()
      local received
      logger.configure(logger_options({
        sink = function(record)
          received = record
          record.event = "mutated"
        end,
      }))
      logger.debug("request", { path = "/private/file", item_count = 4 })
      assert.same("mutated", received.event)
      local first_records = logger.records()
      assert.same("request", first_records[#first_records].event)
      assert.same(4, first_records[#first_records].fields.item_count)

      logger.configure(logger_options({
        sink = function()
          error("sink-secret")
        end,
      }))
      logger.debug("request", {})
      local records = logger.records()
      assert.same("debug_sink_failed", records[#records].event)
      assert.falsy(string.find(vim.inspect(records), "sink-secret", 1, true))
      logger.configure(logger_options({ enabled = false }))
    end,
  },
  {
    name = "engine lifecycle emits structured private request records",
    run = function()
      local completion = require("partial_completion")
      local static = require("partial_completion.providers.static")
      completion.setup({ debug = { enabled = true, max_entries = 20 } })
      completion.clear_debug_records()
      completion.register_provider(
        "phase-seven-log",
        static.new({
          { id = "alpha", label = "alpha", insert_text = "alpha" },
        })
      )
      local terminal
      completion.complete({
        category = "generic",
        query = "/private/query",
        cwd = "/private/worktree",
        provider = "phase-seven-log",
      }, function(update)
        terminal = update.done
      end)
      assert.truthy(terminal)
      local records = completion.debug_records()
      assert.same("request_started", records[1].event)
      assert.same("request_finished", records[#records].event)
      local serialized = vim.inspect(records)
      assert.falsy(string.find(serialized, "/private/query", 1, true))
      assert.falsy(string.find(serialized, "/private/worktree", 1, true))
      completion.setup({})
    end,
  },
  {
    name = "configuration rejects unknown fields and health reports the last rejection",
    run = function()
      assert.raises("setup.typo is unknown", function()
        config.resolve({ typo = true })
      end)
      assert.raises("filesystem.typo is unknown", function()
        config.resolve({ filesystem = { typo = true } })
      end)
      assert.raises("debug.max_entries", function()
        config.resolve({ debug = { max_entries = 0 } })
      end)
      assert.raises("filesystem.cache.ttl_ms", function()
        config.resolve({ filesystem = { cache = { ttl_ms = 0 / 0 } } })
      end)
      assert.raises("filesystem.cache.ttl_ms", function()
        config.resolve({ filesystem = { cache = { ttl_ms = math.huge } } })
      end)
      assert.raises("native.request.typo is unknown", function()
        config.resolve({ native = { request = { typo = true } } })
      end)
      assert.raises("native.request.limit", function()
        config.resolve({ native = { request = { limit = 0 } } })
      end)

      local completion = require("partial_completion")
      local ok = pcall(completion.setup, { typo = true })
      assert.falsy(ok)
      local report = health.report()
      local configuration
      for _, item in ipairs(report) do
        if item.name == "configuration" then
          configuration = item
        end
      end
      assert.same("error", configuration.status)
      assert.truthy(string.find(configuration.message, "setup.typo", 1, true))
      completion.setup({})
    end,
  },
  {
    name = "health checks version configuration and optional adapter availability",
    run = function()
      local report = health.report({
        has_version = false,
        snapshot = {
          config = config.resolve({}),
          native_enabled = false,
        },
        runtime_files = function(path)
          return path == "lua/telescope/init.lua" and { "/runtime/telescope.lua" } or {}
        end,
      })
      local by_name = {}
      for _, item in ipairs(report) do
        by_name[item.name] = item
      end
      assert.same("error", by_name.neovim.status)
      assert.same("ok", by_name.configuration.status)
      assert.truthy(string.find(by_name["adapter:Telescope"].message, "available", 1, true))
      assert.truthy(string.find(by_name["adapter:Blink"].message, "not installed", 1, true))
    end,
  },
}
