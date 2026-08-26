local assert = require("tests.helpers.assertions")
local config = require("partial_completion.config")
local Engine = require("partial_completion.engine")
local Providers = require("partial_completion.providers")

local function create_engine(provider, provider_options, engine_config)
  local providers = Providers.new()
  providers:register("test", provider, provider_options)
  return Engine.new(engine_config or config.resolve({}), providers)
end

return {
  {
    name = "streamed provider chunks become complete sorted snapshots",
    run = function()
      local engine = create_engine({
        api_version = 1,
        categories = { "generic" },
        complete = function(_, emit, done)
          emit({ { id = "prefix", label = "alphabet", insert_text = "alphabet", source_order = 2 } })
          emit({ { id = "exact", label = "alp", insert_text = "alp", source_order = 1 } })
          done(nil)
          return { cancel = function() end }
        end,
      })
      local updates = {}
      engine:complete({ category = "generic", query = "alp", provider = "test" }, function(update)
        updates[#updates + 1] = update
      end)
      assert.same(3, #updates)
      assert.same({ "prefix" }, { updates[1].items[1].id })
      assert.same({ "exact", "prefix" }, { updates[2].items[1].id, updates[2].items[2].id })
      assert.truthy(updates[3].done)
    end,
  },
  {
    name = "provider replacement snapshots retract provisional candidates",
    run = function()
      local engine = create_engine({
        api_version = 1,
        categories = { "generic" },
        complete = function(_, emit, done)
          emit({
            { id = "provisional", label = "alphabet", insert_text = "alphabet" },
          }, { replace = true })
          emit({
            { id = "final", label = "alpine", insert_text = "alpine" },
          }, { replace = true })
          done(nil)
          return { cancel = function() end }
        end,
      })
      local updates = {}
      engine:complete({ category = "generic", query = "alp", provider = "test" }, function(update)
        updates[#updates + 1] = update
      end)
      assert.same({ "provisional" }, { updates[1].items[1].id })
      assert.same({ "final" }, { updates[2].items[1].id })
      assert.same({ "final" }, { updates[3].items[1].id })
      assert.truthy(updates[3].done)
    end,
  },
  {
    name = "replacement snapshots recalculate incompleteness",
    run = function()
      local engine = create_engine({
        api_version = 1,
        categories = { "generic" },
        complete = function(_, emit, done)
          emit({ { id = "old", label = "alpha", insert_text = "alpha" } }, {
            replace = true,
            is_incomplete = true,
          })
          emit({ { id = "final", label = "alpine", insert_text = "alpine" } }, {
            replace = true,
            is_incomplete = false,
          })
          done(nil)
          return { cancel = function() end }
        end,
      })
      local final
      engine:complete({ category = "generic", query = "a", provider = "test" }, function(update)
        final = update
      end)
      assert.falsy(final.is_incomplete)
      assert.same("final", final.items[1].id)
    end,
  },
  {
    name = "cancel is idempotent and makes late callbacks silent",
    run = function()
      local late_emit
      local late_done
      local cancel_count = 0
      local engine = create_engine({
        api_version = 1,
        categories = { "generic" },
        complete = function(_, emit, done)
          late_emit = emit
          late_done = done
          return {
            cancel = function()
              cancel_count = cancel_count + 1
            end,
          }
        end,
      })
      local updates = {}
      local handle = engine:complete({ category = "generic", query = "a", provider = "test" }, function(update)
        updates[#updates + 1] = update
      end)
      handle:cancel()
      handle:cancel()
      late_emit({ { id = "late", label = "alpha", insert_text = "alpha" } })
      late_done(nil)
      assert.same(1, cancel_count)
      assert.same({}, updates)
    end,
  },
  {
    name = "provider failures are structured terminal updates",
    run = function()
      local engine = create_engine({
        api_version = 1,
        categories = { "generic" },
        complete = function()
          error("boom")
        end,
      })
      local updates = {}
      engine:complete({ category = "generic", query = "a", provider = "test" }, function(update)
        updates[#updates + 1] = update
      end)
      assert.same(1, #updates)
      assert.truthy(updates[1].done)
      assert.same("provider_error", updates[1].error.code)
    end,
  },
  {
    name = "request validation rejects reserved and split UTF-8 ranges",
    run = function()
      local engine = create_engine({
        api_version = 1,
        categories = { "generic" },
        complete = function(_, _, done)
          done(nil)
          return { cancel = function() end }
        end,
      })
      assert.raises("engine%-owned", function()
        engine:complete({ category = "generic", query = "a", provider = "test", request_id = 1 }, function() end)
      end)
      assert.raises("UTF%-8 byte boundary", function()
        engine:complete({
          category = "generic",
          query = "é",
          provider = "test",
          source_text = "é",
          cursor_byte = 1,
          replacement = { start_byte = 0, end_byte = 1 },
        }, function() end)
      end)
      assert.raises("unknown matching_style", function()
        engine:complete(
          { category = "generic", query = "a", provider = "test", matching_style = "other" },
          function() end
        )
      end)
      local windows_done = false
      engine:complete({
        category = "generic",
        query = "a",
        provider = "test",
        cwd = [[C:\work\project]],
        context = { platform = "windows" },
      }, function(update)
        windows_done = update.done
      end)
      assert.truthy(windows_done)
      assert.raises("absolute path", function()
        engine:complete({
          category = "generic",
          query = "a",
          provider = "test",
          cwd = [[C:relative]],
          context = { platform = "windows" },
        }, function() end)
      end)
    end,
  },
  {
    name = "streaming requests retain their matcher configuration snapshot",
    run = function()
      local later_emit
      local later_done
      local engine = create_engine({
        api_version = 1,
        categories = { "generic" },
        complete = function(_, emit, done)
          emit({ { id = "lower", label = "alpha", insert_text = "alpha" } })
          later_emit = emit
          later_done = done
          return { cancel = function() end }
        end,
      }, nil, config.resolve({ categories = { generic = { case_mode = "sensitive" } } }))
      local updates = {}
      engine:complete({ category = "generic", query = "a", provider = "test" }, function(update)
        updates[#updates + 1] = update
      end)
      engine:set_config(config.resolve({ categories = { generic = { case_mode = "insensitive" } } }))
      later_emit({ { id = "upper", label = "Alpha", insert_text = "Alpha" } })
      later_done(nil)
      assert.same({ "lower" }, { updates[#updates].items[1].id })
      assert.same(1, #updates[#updates].items)
    end,
  },
  {
    name = "consumer callback failures do not become provider failures",
    run = function()
      local provider_continued = false
      local callback_count = 0
      local engine = create_engine({
        api_version = 1,
        categories = { "generic" },
        complete = function(_, emit, done)
          emit({ { id = "alpha", label = "alpha", insert_text = "alpha" } })
          provider_continued = true
          done(nil)
          return { cancel = function() end }
        end,
      })
      assert.raises("completion callback failed:.*consumer%-sentinel", function()
        engine:complete({ category = "generic", query = "a", provider = "test" }, function()
          callback_count = callback_count + 1
          error("consumer-sentinel")
        end)
      end)
      assert.truthy(provider_continued)
      assert.same(1, callback_count)
    end,
  },
  {
    name = "already-filtered providers retain authoritative candidates",
    run = function()
      local engine = create_engine({
        api_version = 1,
        categories = { "generic" },
        complete = function(_, emit, done)
          emit({
            { id = "later", label = "not-a-match", insert_text = "not-a-match", source_order = 2 },
            { id = "first", label = "also-not-a-match", insert_text = "also-not-a-match", source_order = 1 },
          })
          done(nil)
          return { cancel = function() end }
        end,
      }, { already_filtered = true })
      local final
      engine:complete({ category = "generic", query = "zzz", provider = "test" }, function(update)
        final = update
      end)
      assert.same({ "first", "later" }, { final.items[1].id, final.items[2].id })
      assert.same("provider", final.items[1].match.level)
      assert.truthy(final.items[1].match.score > final.items[2].match.score)
    end,
  },
  {
    name = "configured Emacs matching style is snapshotted and forwarded to providers",
    run = function()
      local observed_style
      local engine = create_engine({
        api_version = 1,
        categories = { "generic" },
        complete = function(request, emit, done)
          observed_style = request.matching_style
          emit({
            { id = "long", label = "debug-long-list", insert_text = "debug-long-list" },
            { id = "short", label = "debug-list", insert_text = "debug-list" },
          })
          done(nil)
          return { cancel = function() end }
        end,
      }, nil, config.resolve({ matching_style = "emacs" }))
      local final
      engine:complete({ category = "generic", query = "de-li", provider = "test" }, function(update)
        final = update
      end)
      assert.same("emacs", observed_style)
      assert.same({ "short", "long" }, { final.items[1].id, final.items[2].id })
    end,
  },
  {
    name = "invalid source ordinals are rejected as incomplete items",
    run = function()
      local engine = create_engine({
        api_version = 1,
        categories = { "generic" },
        complete = function(_, emit, done)
          emit({
            { id = "valid", label = "alpha", insert_text = "alpha", source_order = 1 },
            { id = "nan", label = "alpine", insert_text = "alpine", source_order = 0 / 0 },
          })
          done(nil)
          return { cancel = function() end }
        end,
      })
      local final
      engine:complete({ category = "generic", query = "a", provider = "test" }, function(update)
        final = update
      end)
      assert.same({ "valid" }, { final.items[1].id })
      assert.truthy(final.is_incomplete)
    end,
  },
  {
    name = "cyclic and excessively deep provider data is isolated across async emits",
    run = function()
      local engine = create_engine({
        api_version = 1,
        categories = { "generic" },
        complete = function(_, emit, done)
          vim.schedule(function()
            local cycle = {}
            cycle.self = cycle
            local deep = {}
            local cursor = deep
            for _ = 1, 70 do
              cursor.child = {}
              cursor = cursor.child
            end
            emit({
              { id = "cycle", label = "alpha", insert_text = "alpha", data = cycle },
              { id = "deep", label = "alpine", insert_text = "alpine", data = deep },
              { id = "valid", label = "atlas", insert_text = "atlas", data = { safe = true } },
            })
            done(nil)
          end)
          return { cancel = function() end }
        end,
      })
      local final
      engine:complete({ category = "generic", query = "a", provider = "test" }, function(update)
        final = update
      end)
      assert.truthy(vim.wait(1000, function()
        return final and final.done
      end, 1))
      assert.same({ "valid" }, { final.items[1].id })
      assert.truthy(final.is_incomplete)
    end,
  },
  {
    name = "provider data accepts exactly 64 tables and rejects scalar and empty item fields",
    run = function()
      local deep = {}
      local cursor = deep
      for _ = 2, 64 do
        cursor.child = {}
        cursor = cursor.child
      end
      local engine = create_engine({
        api_version = 1,
        categories = { "generic" },
        complete = function(_, emit, done)
          emit({
            { id = "deep", label = "alpha", insert_text = "alpha", data = deep },
            { id = "scalar", label = "alpine", insert_text = "alpine", data = 42 },
            { id = "empty-label", label = "", insert_text = "atlas" },
            { id = "empty-insert", label = "atom", insert_text = "" },
          })
          done(nil)
        end,
      })
      local final
      engine:complete({ category = "generic", query = "a", provider = "test" }, function(update)
        final = update
      end)
      assert.same({ "deep" }, { final.items[1].id })
      assert.truthy(final.is_incomplete)
      local copied = final.items[1].data
      for _ = 2, 64 do
        copied = copied.child
      end
      assert.truthy(type(copied) == "table")
    end,
  },
  {
    name = "provider boundary requires unfinished cancel handles and contains hostile async values",
    run = function()
      local missing_handle = create_engine({
        api_version = 1,
        categories = { "generic" },
        complete = function() end,
      })
      local missing_final
      missing_handle:complete({ category = "generic", query = "a", provider = "test" }, function(update)
        missing_final = update
      end)
      assert.same("invalid_provider_handle", missing_final.error.code)

      local invalid_metadata = create_engine({
        api_version = 1,
        categories = { "generic" },
        complete = function(_, emit)
          vim.schedule(function()
            emit({}, 42)
          end)
          return { cancel = function() end }
        end,
      })
      local metadata_final
      invalid_metadata:complete({ category = "generic", query = "a", provider = "test" }, function(update)
        metadata_final = update
      end)
      assert.truthy(vim.wait(1000, function()
        return metadata_final and metadata_final.done
      end, 1))
      assert.same("invalid_provider_emission", metadata_final.error.code)

      local hostile_error = setmetatable({}, {
        __tostring = function()
          error("hostile tostring")
        end,
      })
      local hostile_done = create_engine({
        api_version = 1,
        categories = { "generic" },
        complete = function(_, _, done)
          vim.schedule(function()
            done(hostile_error)
          end)
          return { cancel = function() end }
        end,
      })
      local hostile_final
      hostile_done:complete({ category = "generic", query = "a", provider = "test" }, function(update)
        hostile_final = update
      end)
      assert.truthy(vim.wait(1000, function()
        return hostile_final and hostile_final.done
      end, 1))
      assert.same("provider_error", hostile_final.error.code)
      assert.same("<unprintable provider value>", hostile_final.error.message)
    end,
  },
  {
    name = "re-emitting an id preserves its first fallback source ordinal",
    run = function()
      local engine = create_engine({
        api_version = 1,
        categories = { "generic" },
        complete = function(_, emit, done)
          emit({
            { id = "a", label = "alpha", insert_text = "alpha" },
            { id = "b", label = "alpha", insert_text = "alpha" },
          })
          emit({ { id = "a", label = "alpha", insert_text = "alpha" } })
          done(nil)
          return { cancel = function() end }
        end,
      })
      local final
      engine:complete({ category = "generic", query = "a", provider = "test" }, function(update)
        final = update
      end)
      assert.same({ "a", "b" }, { final.items[1].id, final.items[2].id })
      assert.same(1, final.items[1].source_order)
      assert.same(2, final.items[2].source_order)
    end,
  },
}
