local assert = require("tests.helpers.assertions")
local config = require("partial_completion.config")
local Engine = require("partial_completion.engine")
local Providers = require("partial_completion.providers")
local filesystem = require("partial_completion.providers.filesystem")

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

local function mkdir(path)
  assert.truthy(vim.fn.mkdir(path, "p") == 1 or vim.fn.isdirectory(path) == 1, "failed to create " .. path)
end

local function write(path)
  vim.fn.writefile({ "fixture" }, path)
end

local function run(provider, request, timeout)
  local result = {
    items = {},
    updates = 0,
    incomplete = false,
    done_count = 0,
    error = nil,
  }
  local handle = provider.complete(request, function(items, metadata)
    result.fast_event = result.fast_event or vim.in_fast_event()
    result.updates = result.updates + 1
    if metadata and metadata.replace == true then
      result.items = {}
      result.incomplete = metadata.is_incomplete == true
    else
      result.incomplete = result.incomplete or (metadata and metadata.is_incomplete == true)
    end
    for _, item in ipairs(items) do
      result.items[#result.items + 1] = item
    end
  end, function(err)
    result.fast_event = result.fast_event or vim.in_fast_event()
    result.done_count = result.done_count + 1
    result.error = err
  end)
  local completed = vim.wait(timeout or 2000, function()
    return result.done_count > 0
  end, 1)
  if not completed then
    handle:cancel()
    error("filesystem completion timed out", 2)
  end
  assert.same(1, result.done_count)
  assert.falsy(result.fast_event, "filesystem callback escaped from fast-event context")
  return result, handle
end

local function texts(items)
  local result = {}
  for _, item in ipairs(items) do
    result[#result + 1] = item.insert_text
  end
  table.sort(result)
  return result
end

return {
  {
    name = "component traversal preserves ambiguity and never skips a directory",
    run = function()
      with_root(function(root)
        mkdir(root .. "/Desktop/Library")
        mkdir(root .. "/Desktop/Local/Library")
        mkdir(root .. "/Developer/lib")
        local provider = filesystem.new({ cache = { ttl_ms = 0 } })
        local result = run(provider, {
          category = "path",
          query = "de/li",
          cwd = root,
          case_mode = "filesystem",
          limit = 20,
          context = { filesystem_case_sensitive = false },
        })
        assert.same({ "Desktop/Library/", "Developer/lib/" }, texts(result.items))
        assert.same(nil, result.error)
      end)
    end,
  },
  {
    name = "Emacs matching style traverses wildcards repeated and explicitly typed structural components",
    run = function()
      with_root(function(root)
        mkdir(root .. "/Desktop/Library")
        mkdir(root .. "/Desktop/Local/Library")
        mkdir(root .. "/Developer/lib")
        mkdir(root .. "/foo/bar")
        mkdir(root .. "/fizz/barn")
        local provider = filesystem.new({ cache = { ttl_ms = 0 } })
        local function complete(query)
          return texts(run(provider, {
            category = "path",
            query = query,
            cwd = root,
            case_mode = "insensitive",
            matching_style = "emacs",
            limit = 30,
          }).items)
        end

        assert.same({ "fizz/barn/", "foo/bar/" }, complete("f*/ba"))
        assert.same({ "Desktop/Local/Library/" }, complete("de//li"))
        assert.same({ "foo/./bar/" }, complete("foo/./ba"))
        assert.same({ "foo/../foo/bar/" }, complete("foo/../fo/ba"))
        assert.same({}, complete("foo/."))
      end)
    end,
  },
  {
    name = "built-in public provider preserves generations and resolved filesystem case",
    run = function()
      with_root(function(root)
        mkdir(root .. "/Desktop/Library")
        local completion = require("partial_completion")
        completion.setup({ filesystem = { case_sensitive = false, cache = { ttl_ms = 60000 } } })
        local updates = {}
        local handle = completion.complete({
          category = "path",
          query = "de/li",
          cwd = root,
          case_mode = "filesystem",
          limit = 20,
        }, function(update)
          updates[#updates + 1] = update
        end)
        assert.truthy(vim.wait(2000, function()
          return updates[#updates] and updates[#updates].done
        end, 1))
        local final = updates[#updates]
        assert.same({ "Desktop/Library/" }, texts(final.items))
        assert.same(final.request_id, final.generation)
        assert.same(nil, final.error)
        local entries_before = filesystem.cache_stats().entries
        completion.setup({ filesystem = { case_sensitive = false, cache = { ttl_ms = 60000 } } })
        assert.same(entries_before, filesystem.cache_stats().entries)
        handle:cancel()
      end)
    end,
  },
  {
    name = "default path completion is insensitive on a case-sensitive filesystem",
    run = function()
      with_root(function(root)
        mkdir(root .. "/Desktop/Library")
        local provider = filesystem.new({
          case_sensitive = true,
          cache = { ttl_ms = 0 },
        })
        local providers = Providers.new()
        providers:register("filesystem", provider)
        local engine = Engine.new(config.resolve({}), providers)
        local updates = {}
        local handle = engine:complete({
          category = "path",
          query = "de/li",
          cwd = root,
          limit = 20,
          provider = "filesystem",
        }, function(update)
          updates[#updates + 1] = update
        end)
        assert.truthy(vim.wait(2000, function()
          return updates[#updates] and updates[#updates].done
        end, 1))
        local final = updates[#updates]
        assert.same({ "Desktop/Library/" }, texts(final.items))
        assert.same(nil, final.error)
        handle:cancel()
      end)
    end,
  },
  {
    name = "final result limits follow deterministic full-path ordering",
    run = function()
      with_root(function(root)
        mkdir(root .. "/Desktop/a")
        mkdir(root .. "/dotfiles/b")
        local provider = filesystem.new({ cache = { ttl_ms = 0 } })
        local function labels(limit)
          local result = run(provider, {
            category = "path",
            query = "d/",
            cwd = root,
            case_mode = "insensitive",
            limit = limit,
          })
          local values = {}
          for _, item in ipairs(result.items) do
            values[#values + 1] = item.label
          end
          return values, result.incomplete
        end

        assert.same({ "Desktop/a/" }, (labels(1)))
        assert.same({ "Desktop/a/", "dotfiles/b/" }, (labels(2)))
        assert.same({ "Desktop/a/", "dotfiles/b/" }, (labels(20)))
        local _, incomplete = labels(1)
        assert.truthy(incomplete)
      end)
    end,
  },
  {
    name = "explicit path subsequence reaches filesystem discovery",
    run = function()
      with_root(function(root)
        mkdir(root .. "/Desktop")
        local provider = filesystem.new({ cache = { ttl_ms = 0 } })
        local result = run(provider, {
          category = "path",
          query = "Dktp",
          cwd = root,
          case_mode = "sensitive",
          allow_subsequence = true,
          limit = 20,
        })
        assert.same({ "Desktop/" }, texts(result.items))
      end)
    end,
  },
  {
    name = "filesystem case policy is resolved for each scanned directory",
    run = function()
      with_root(function(root)
        mkdir(root .. "/Desktop/Library")
        mkdir(root .. "/Developer/Library")
        local physical_root = vim.uv.fs_realpath(root)
        assert.truthy(physical_root)
        local provider = filesystem.new({ cache = { ttl_ms = 0 } })
        local result = run(provider, {
          category = "path",
          query = "de/li",
          cwd = root,
          case_mode = "filesystem",
          limit = 20,
          context = {
            filesystem_case_sensitive = {
              [physical_root] = false,
              [physical_root .. "/Desktop"] = true,
              [physical_root .. "/Developer"] = false,
            },
          },
        })
        assert.same({ "Developer/Library/" }, texts(result.items))
      end)
    end,
  },
  {
    name = "filesystem case-policy cache shares configured LRU bounds",
    run = function()
      with_root(function(root)
        local provider = filesystem.new({
          cache = { max_entries = 2, max_bytes = 1024, ttl_ms = 60000 },
        })
        for index = 1, 3 do
          local directory = string.format("%s/root-%d", root, index)
          mkdir(directory)
          write(directory .. "/Alpha.txt")
          run(provider, {
            category = "path",
            query = "A",
            cwd = directory,
            case_mode = "filesystem",
            limit = 20,
          })
        end
        local retained = root .. "/root-3"
        run(provider, {
          category = "path",
          query = "A",
          cwd = retained,
          case_mode = "filesystem",
          limit = 20,
        })
        local stats = provider.cache_stats()
        assert.truthy(stats.case_entries <= 2)
        assert.truthy(stats.case_evictions >= 1)
        assert.truthy(stats.case_hits >= 1)
        assert.truthy(stats.case_misses >= 3)
        provider.invalidate_cache(retained)
        assert.truthy(provider.cache_stats().case_invalidations >= 1)
      end)
    end,
  },
  {
    name = "provider streams chunks and enforces result branch and scan limits",
    run = function()
      with_root(function(root)
        for index = 1, 12 do
          mkdir(string.format("%s/dir%02d", root, index))
          write(string.format("%s/dir%02d/item.txt", root, index))
        end
        local provider = filesystem.new({
          branch_limit = 4,
          max_entries_scanned = 1000,
          emit_chunk_size = 2,
          cache = { ttl_ms = 0 },
        })
        local result = run(provider, {
          category = "path",
          query = "d/i",
          cwd = root,
          case_mode = "sensitive",
          limit = 3,
        })
        assert.same(3, #result.items)
        assert.truthy(result.updates >= 2)
        assert.truthy(result.incomplete)

        local bounded = filesystem.new({
          max_entries_scanned = 5,
          cache = { ttl_ms = 0 },
        })
        local scan_result = run(bounded, {
          category = "path",
          query = "",
          cwd = root,
          case_mode = "sensitive",
          limit = 100,
        })
        assert.truthy(#scan_result.items <= 5)
        assert.truthy(scan_result.incomplete)
      end)
    end,
  },
  {
    name = "cache has measurable warm hits and explicit invalidation",
    run = function()
      with_root(function(root)
        write(root .. "/alpha.txt")
        local options = { cache = { ttl_ms = 60000 } }
        local provider = filesystem.new(options)
        local request = {
          category = "path",
          query = "a",
          cwd = root,
          case_mode = "sensitive",
          limit = 20,
        }
        assert.same({ "alpha.txt" }, texts(run(provider, request).items))
        local entries_before = provider.cache_stats().entries
        provider.configure(options)
        assert.same(entries_before, provider.cache_stats().entries)
        write(root .. "/alpine.txt")
        assert.same({ "alpha.txt" }, texts(run(provider, request).items))
        assert.truthy(provider.cache_stats().hits >= 1)
        provider.invalidate_cache(root)
        assert.same({ "alpha.txt", "alpine.txt" }, texts(run(provider, request).items))
        local stats = provider.cache_stats()
        assert.truthy(stats.misses >= 2)
        assert.truthy(stats.invalidations >= 1)
      end)
    end,
  },
  {
    name = "case hidden literal and Unicode policies are filesystem-safe",
    run = function()
      with_root(function(root)
        write(root .. "/CamelCase.txt")
        write(root .. "/.secret")
        write(root .. "/[draft]*?.txt")
        write(root .. "/café.txt")
        local provider = filesystem.new({ cache = { ttl_ms = 0 } })
        local base = { category = "path", cwd = root, limit = 20 }

        base.query = "ca"
        base.case_mode = "filesystem"
        base.context = { filesystem_case_sensitive = false }
        assert.same({ "CamelCase.txt", "café.txt" }, texts(run(provider, base).items))
        base.context = { filesystem_case_sensitive = true }
        assert.same({ "café.txt" }, texts(run(provider, base).items))
        base.context = nil
        base.case_mode = "smart"
        assert.same({ "CamelCase.txt", "café.txt" }, texts(run(provider, base).items))
        base.query = "Ca"
        assert.same({ "CamelCase.txt" }, texts(run(provider, base).items))
        base.query = "[d"
        base.case_mode = "sensitive"
        assert.same({ "[draft]*?.txt" }, texts(run(provider, base).items))
        base.query = "."
        assert.same({ ".secret" }, texts(run(provider, base).items))
        base.query = ""
        assert.falsy(vim.tbl_contains(texts(run(provider, base).items), ".secret"))

        local hidden = filesystem.new({ hidden = "always", cache = { ttl_ms = 0 } })
        assert.truthy(vim.tbl_contains(texts(run(hidden, base).items), ".secret"))
      end)
    end,
  },
  {
    name = "cached entries that disappear are discarded before emission",
    run = function()
      with_root(function(root)
        write(root .. "/alpha.txt")
        local provider = filesystem.new({ cache = { ttl_ms = 60000 } })
        local request = {
          category = "path",
          query = "a",
          cwd = root,
          case_mode = "sensitive",
          limit = 20,
        }
        assert.same({ "alpha.txt" }, texts(run(provider, request).items))
        assert.same(0, vim.fn.delete(root .. "/alpha.txt"))
        assert.same({}, run(provider, request).items)
        assert.truthy(provider.cache_stats().hits >= 1)
      end)
    end,
  },
  {
    name = "stale cached validation rescans beyond the bounded reserve",
    run = function()
      with_root(function(root)
        for byte = string.byte("a"), string.byte("j") do
          write(root .. "/" .. string.char(byte))
        end
        local provider = filesystem.new({ cache = { ttl_ms = 60000 } })
        local request = {
          category = "path",
          query = "",
          cwd = root,
          case_mode = "sensitive",
          limit = 3,
        }
        assert.same({ "a", "b", "c" }, texts(run(provider, request).items))
        for byte = string.byte("a"), string.byte("f") do
          assert.same(0, vim.fn.delete(root .. "/" .. string.char(byte)))
        end
        assert.same({ "g", "h", "i" }, texts(run(provider, request).items))
        assert.truthy(provider.cache_stats().invalidations >= 1)
      end)
    end,
  },
  {
    name = "stale retry clears provisional truncation when the uncached result is complete",
    run = function()
      with_root(function(root)
        for byte = string.byte("a"), string.byte("f") do
          write(root .. "/" .. string.char(byte))
        end
        local provider = filesystem.new({ cache = { ttl_ms = 60000 } })
        local request = {
          category = "path",
          query = "",
          cwd = root,
          case_mode = "sensitive",
          limit = 2,
        }
        assert.same({ "a", "b" }, texts(run(provider, request).items))
        for byte = string.byte("a"), string.byte("d") do
          assert.same(0, vim.fn.delete(root .. "/" .. string.char(byte)))
        end
        local refreshed = run(provider, request)
        assert.same({ "e", "f" }, texts(refreshed.items))
        assert.falsy(refreshed.incomplete)
      end)
    end,
  },
  {
    name = "cached entry type transitions use authoritative stat results",
    run = function()
      with_root(function(root)
        local target = root .. "/alpha"
        write(target)
        local provider = filesystem.new({ cache = { ttl_ms = 60000 } })
        local request = {
          category = "path",
          query = "a",
          cwd = root,
          case_mode = "sensitive",
          limit = 20,
        }
        assert.same({ "alpha" }, texts(run(provider, request).items))

        assert.same(0, vim.fn.delete(target))
        mkdir(target)
        request.context = { only_directories = true }
        local directory = run(provider, request)
        assert.same({ "alpha/" }, texts(directory.items))
        assert.same("directory", directory.items[1].kind)

        assert.same(0, vim.fn.delete(target, "d"))
        write(target)
        request.context = nil
        local file = run(provider, request)
        assert.same({ "alpha" }, texts(file.items))
        assert.same("file", file.items[1].kind)
      end)
    end,
  },
  {
    name = "cached intermediate components revalidate directory and file transitions",
    run = function()
      with_root(function(root)
        local target = root .. "/alpha"
        mkdir(target)
        write(target .. "/x.txt")
        local provider = filesystem.new({ cache = { ttl_ms = 60000 } })
        local request = {
          category = "path",
          query = "a/x",
          cwd = root,
          case_mode = "sensitive",
          limit = 20,
        }
        assert.same({ "alpha/x.txt" }, texts(run(provider, request).items))

        assert.same(0, vim.fn.delete(target, "rf"))
        write(target)
        local became_file = run(provider, request)
        assert.same({}, became_file.items)
        assert.same(nil, became_file.error)

        run(provider, {
          category = "path",
          query = "a",
          cwd = root,
          case_mode = "sensitive",
          limit = 20,
        })
        assert.same(0, vim.fn.delete(target))
        mkdir(target)
        write(target .. "/x.txt")
        assert.same({ "alpha/x.txt" }, texts(run(provider, request).items))
      end)
    end,
  },
  {
    name = "duplicate search roots deduplicate before the top-K limit in stable root order",
    run = function()
      with_root(function(root)
        local physical = root .. "/physical"
        mkdir(physical)
        for _, name in ipairs({ "a", "b", "c", "d" }) do
          write(physical .. "/" .. name)
        end
        assert.truthy(vim.uv.fs_symlink(physical, root .. "/alias-one", { dir = true }))
        assert.truthy(vim.uv.fs_symlink(physical, root .. "/alias-two", { dir = true }))
        local provider = filesystem.new({ cache = { ttl_ms = 0 } })
        local result = run(provider, {
          category = "path",
          query = "",
          cwd = root,
          case_mode = "sensitive",
          limit = 3,
          context = {
            search_roots = { physical, root .. "/alias-one", root .. "/alias-two" },
          },
        })
        assert.same({ "a", "b", "c" }, texts(result.items))
        assert.same(physical .. "/a", result.items[1].data.path)
        assert.truthy(result.incomplete)
      end)
    end,
  },
  {
    name = "duplicate search roots retain a valid fallback when the preferred file disappears",
    run = function()
      with_root(function(root)
        local first = root .. "/first"
        local second = root .. "/second"
        mkdir(first)
        mkdir(second)
        write(first .. "/alpha.txt")
        write(second .. "/alpha.txt")
        local provider = filesystem.new({ cache = { ttl_ms = 60000 } })
        local request = {
          category = "path",
          query = "a",
          cwd = root,
          case_mode = "sensitive",
          limit = 1,
          context = { search_roots = { first, second } },
        }
        local preferred = run(provider, request)
        assert.same(first .. "/alpha.txt", preferred.items[1].data.path)
        assert.same(0, vim.fn.delete(first .. "/alpha.txt"))
        local fallback = run(provider, request)
        assert.same({ "alpha.txt" }, texts(fallback.items))
        assert.same(second .. "/alpha.txt", fallback.items[1].data.path)
        assert.same(nil, fallback.error)
      end)
    end,
  },
  {
    name = "symlinks preserve insertion spelling and loops and broken links stay bounded",
    run = function()
      with_root(function(root)
        mkdir(root .. "/real")
        write(root .. "/real/module.lua")
        assert.truthy(vim.uv.fs_symlink(root .. "/real", root .. "/link", { dir = true }))
        assert.truthy(vim.uv.fs_symlink(root, root .. "/loop", { dir = true }))
        assert.truthy(vim.uv.fs_symlink(root .. "/missing", root .. "/broken"))
        assert.truthy(vim.uv.fs_symlink(root .. "/self", root .. "/self"))
        assert.truthy(vim.uv.fs_symlink(root .. "/two-b", root .. "/two-a"))
        assert.truthy(vim.uv.fs_symlink(root .. "/two-a", root .. "/two-b"))
        local provider = filesystem.new({ cache = { ttl_ms = 0 } })

        local linked = run(provider, {
          category = "path",
          query = "li/mo",
          cwd = root,
          case_mode = "sensitive",
          limit = 20,
        })
        assert.same({ "link/module.lua" }, texts(linked.items))
        assert.same(root .. "/real/module.lua", linked.items[1].data.path)

        local looped = run(provider, {
          category = "path",
          query = "lo/lo/mo",
          cwd = root,
          case_mode = "sensitive",
          limit = 20,
        })
        assert.same({}, looped.items)
        local broken = run(provider, {
          category = "path",
          query = "bro",
          cwd = root,
          case_mode = "sensitive",
          limit = 20,
        })
        assert.same("symlink", broken.items[1].kind)
        assert.truthy(broken.items[1].data.broken)

        for _, query in ipairs({ "se/ch", "two-a/ch" }) do
          local loop = run(provider, {
            category = "path",
            query = query,
            cwd = root,
            case_mode = "sensitive",
            limit = 20,
          })
          assert.same({}, loop.items)
          assert.same(nil, loop.error)
        end
        local self_link = run(provider, {
          category = "path",
          query = "se",
          cwd = root,
          case_mode = "sensitive",
          limit = 20,
        })
        assert.same("symlink", self_link.items[1].kind)
        assert.truthy(self_link.items[1].data.broken)
      end)
    end,
  },
  {
    name = "cached directory-only validation is prefiltered bounded and concurrent",
    run = function()
      with_root(function(root)
        for index = 1, 300 do
          write(string.format("%s/directory-file-%03d", root, index))
        end
        mkdir(root .. "/directory-target")
        local provider = filesystem.new({ cache = { ttl_ms = 60000 } })
        run(provider, {
          category = "path",
          query = "directory-",
          cwd = root,
          case_mode = "sensitive",
          limit = 400,
        })
        local before = provider.cache_stats().stat_calls
        local directories = run(provider, {
          category = "path",
          query = "directory-t",
          cwd = root,
          case_mode = "sensitive",
          limit = 5,
          context = { only_directories = true },
        })
        local after = provider.cache_stats()
        assert.same({ "directory-target/" }, texts(directories.items))
        assert.truthy(after.stat_calls - before <= 10)
        assert.truthy(after.max_concurrent_stats >= 2)
      end)
    end,
  },
  {
    name = "case probing uses non-following stat for a dangling symlink entry",
    run = function()
      with_root(function(root)
        assert.truthy(vim.uv.fs_symlink(root .. "/missing", root .. "/Alpha"))
        write(root .. "/Bravo.txt")
        local original_lstat = vim.uv.fs_lstat
        local ok, err = xpcall(function()
          vim.uv.fs_lstat = function(path, callback)
            if string.sub(path, -6) == "/alpha" then
              path = string.sub(path, 1, -6) .. "/Alpha"
            end
            return original_lstat(path, callback)
          end
          local provider = filesystem.new({ cache = { ttl_ms = 0 } })
          local result = run(provider, {
            category = "path",
            query = "br",
            cwd = root,
            case_mode = "filesystem",
            limit = 20,
          })
          assert.same({ "Bravo.txt" }, texts(result.items))
        end, debug.traceback)
        vim.uv.fs_lstat = original_lstat
        assert.truthy(ok, err)
      end)
    end,
  },
  {
    name = "root-only completion suppresses navigation and reports authoritative file type",
    run = function()
      with_root(function(root)
        mkdir(root .. "/child")
        write(root .. "/target.txt")
        local provider = filesystem.new({ cache = { ttl_ms = 0 } })
        local navigation = run(provider, {
          category = "path",
          query = "..",
          cwd = root .. "/child",
          case_mode = "sensitive",
          limit = 20,
        })
        assert.same({}, navigation.items)

        local file_root = run(provider, {
          category = "path",
          query = "$TARGET",
          cwd = root,
          case_mode = "sensitive",
          limit = 20,
          context = { env = { TARGET = root .. "/target.txt" } },
        })
        assert.same({ "$TARGET" }, texts(file_root.items))
        assert.same("file", file_root.items[1].kind)

        local directories_only = run(provider, {
          category = "path",
          query = "$TARGET",
          cwd = root,
          case_mode = "sensitive",
          limit = 20,
          context = {
            env = { TARGET = root .. "/target.txt" },
            only_directories = true,
          },
        })
        assert.same({}, directories_only.items)
      end)
    end,
  },
  {
    name = "filesystem completion never invents missing final components",
    run = function()
      with_root(function(root)
        mkdir(root .. "/Documents")
        mkdir(root .. "/Desktop/Library")
        local provider = filesystem.new({ cache = { ttl_ms = 0 } })
        local mixed = run(provider, {
          category = "path",
          query = "D/li",
          cwd = root,
          case_mode = "insensitive",
          limit = 20,
        })
        assert.same({ "Desktop/Library/" }, texts(mixed.items))
        assert.truthy(mixed.items[1].data.exists)

        local missing_final = run(provider, {
          category = "path",
          query = "Des/new-note.md",
          cwd = root,
          case_mode = "sensitive",
          limit = 20,
        })
        assert.same({}, missing_final.items)

        local missing_parent = run(provider, {
          category = "path",
          query = "missing-parent/note.md",
          cwd = root,
          case_mode = "sensitive",
          limit = 20,
        })
        assert.same({}, missing_parent.items)
      end)
    end,
  },
  {
    name = "permission failures are structured and do not invent children",
    run = function()
      with_root(function(root)
        mkdir(root .. "/secret")
        write(root .. "/secret/file.txt")
        assert.truthy(vim.uv.fs_chmod(root .. "/secret", 0))
        local provider = filesystem.new({ cache = { ttl_ms = 0 } })
        local result = run(provider, {
          category = "path",
          query = "sec/fi",
          cwd = root,
          case_mode = "sensitive",
          limit = 20,
        })
        vim.uv.fs_chmod(root .. "/secret", 448)
        assert.same({}, result.items)
        assert.truthy(result.error ~= nil)
        assert.same("permission_denied", result.error.code)
      end)
    end,
  },
  {
    name = "large flat completion replaces an early bounded top-K with the deterministic final top-K",
    run = function()
      with_root(function(root)
        for index = 1, 320 do
          write(string.format("%s/a-very-long-candidate-%03d", root, index))
        end
        write(root .. "/z")
        local provider = filesystem.new({
          scan_chunk_size = 32,
          cache = { ttl_ms = 60000 },
        })
        local request = {
          category = "path",
          query = "",
          cwd = root,
          case_mode = "sensitive",
          limit = 5,
        }
        run(provider, request)

        local snapshots = {}
        local done_count = 0
        provider.complete(request, function(items, metadata)
          if metadata and metadata.replace then
            local snapshot = {}
            for index, item in ipairs(items) do
              snapshot[index] = item.insert_text
            end
            snapshots[#snapshots + 1] = snapshot
          end
        end, function(err)
          assert.same(nil, err)
          done_count = done_count + 1
        end)
        assert.truthy(vim.wait(2000, function()
          return done_count == 1
        end, 1))
        assert.truthy(#snapshots >= 2)
        assert.same(5, #snapshots[1])
        assert.falsy(vim.tbl_contains(snapshots[1], "z"))
        assert.same("z", snapshots[#snapshots][1])
        assert.same(5, #snapshots[#snapshots])
      end)
    end,
  },
  {
    name = "cancellation after the first emitted chunk silences later callbacks",
    run = function()
      with_root(function(root)
        for index = 1, 400 do
          write(string.format("%s/item-%04d", root, index))
        end
        local provider = filesystem.new({
          scan_chunk_size = 1,
          max_entries_scanned = 1000,
          cache = { ttl_ms = 0 },
        })
        local updates = 0
        local done_count = 0
        local handle
        handle = provider.complete({
          category = "path",
          query = "i",
          cwd = root,
          case_mode = "sensitive",
          limit = 100,
        }, function()
          updates = updates + 1
          if updates == 1 then
            handle:cancel()
          end
        end, function()
          done_count = done_count + 1
        end)
        assert.truthy(vim.wait(2000, function()
          return updates == 1
        end, 1))
        handle:cancel()
        vim.wait(100, function()
          return false
        end, 5)
        assert.same(1, updates)
        assert.same(0, done_count)
      end)
    end,
  },
}
