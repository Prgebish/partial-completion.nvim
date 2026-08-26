local M = {}

local function mkdir(path)
  assert(vim.fn.mkdir(path, "p") == 1 or vim.fn.isdirectory(path) == 1, "failed to create " .. path)
end

local function touch(path)
  local descriptor, err = vim.uv.fs_open(path, "w", 420)
  assert(descriptor ~= nil, tostring(err))
  assert(vim.uv.fs_close(descriptor))
end

function M.create(options)
  options = options or {}
  local root = vim.fn.tempname()
  local function build()
    local fixture = {
      root = root,
      home = root .. "/home",
      large_flat = root .. "/large-flat",
      large_count = options.large_count or 4096,
    }

    mkdir(fixture.home .. "/Desktop/Library")
    mkdir(fixture.home .. "/Developer/lib")
    touch(fixture.home .. "/Desktop/Library/module.lua")
    touch(fixture.home .. "/Developer/lib/library.lua")

    fixture.deep = root .. "/deep"
    local deep_path = fixture.deep
    for index = 1, 12 do
      deep_path = deep_path .. string.format("/segment-%02d", index)
    end
    mkdir(deep_path)
    touch(deep_path .. "/terminal.lua")
    fixture.deep_leaf = deep_path .. "/terminal.lua"

    fixture.unicode = root .. "/unicode/Данные/éléments"
    mkdir(fixture.unicode)
    touch(fixture.unicode .. "/café.lua")

    fixture.symlink_target = root .. "/symlink-target/Library"
    mkdir(fixture.symlink_target)
    touch(fixture.symlink_target .. "/linked.lua")
    fixture.symlink = root .. "/linked"
    fixture.has_symlink = vim.uv.fs_symlink(root .. "/symlink-target", fixture.symlink, { dir = true }) == true

    mkdir(fixture.large_flat)
    for index = 1, fixture.large_count do
      touch(fixture.large_flat .. string.format("/icon-material-%05d.lua", index))
    end

    fixture.directory_only = root .. "/directory-only"
    mkdir(fixture.directory_only)
    for index = 1, 300 do
      touch(fixture.directory_only .. string.format("/z-entry-file-%03d", index))
    end
    mkdir(fixture.directory_only .. "/entry-target-a")
    mkdir(fixture.directory_only .. "/entry-target-b")

    fixture.symlink_heavy = root .. "/symlink-heavy"
    fixture.symlink_file_target = root .. "/symlink-file-target"
    fixture.symlink_directory_target = root .. "/symlink-directory-target"
    mkdir(fixture.symlink_heavy)
    mkdir(fixture.symlink_directory_target)
    touch(fixture.symlink_file_target)
    fixture.has_symlink_heavy = true
    for index = 1, 40 do
      fixture.has_symlink_heavy = fixture.has_symlink_heavy
        and vim.uv.fs_symlink(
            fixture.symlink_file_target,
            fixture.symlink_heavy .. string.format("/file-link-%03d", index)
          )
          == true
    end
    for index = 1, 2 do
      fixture.has_symlink_heavy = fixture.has_symlink_heavy
        and vim.uv.fs_symlink(
            fixture.symlink_directory_target,
            fixture.symlink_heavy .. string.format("/dir-link-%03d", index),
            { dir = true }
          )
          == true
    end

    return fixture
  end
  local ok, result = xpcall(build, debug.traceback)
  if not ok then
    vim.fn.delete(root, "rf")
    error(result, 0)
  end
  return result
end

function M.destroy(fixture)
  if fixture ~= nil and fixture.root ~= nil then
    vim.fn.delete(fixture.root, "rf")
  end
end

function M.slow_provider(delay_ms, chunks)
  delay_ms = delay_ms or 20
  chunks = chunks or 4
  return {
    api_version = 1,
    categories = { "generic" },
    complete = function(_, emit, done)
      local active = true
      local index = 0
      local timer = vim.uv.new_timer()
      local next_emit = vim.uv.hrtime() + delay_ms * 1000000
      vim.schedule(function()
        if not active then
          return
        end
        timer:start(1, 1, function()
          if not active then
            return
          end
          local now = vim.uv.hrtime()
          if now < next_emit then
            return
          end
          next_emit = now + delay_ms * 1000000
          index = index + 1
          vim.schedule(function()
            if not active then
              return
            end
            emit({
              {
                id = "slow-" .. index,
                label = "slow-" .. index,
                insert_text = "slow-" .. index,
                source_order = index,
              },
            })
            if index == chunks then
              active = false
              timer:stop()
              timer:close()
              done(nil)
            end
          end)
        end)
      end)
      return {
        cancel = function()
          if not active then
            return
          end
          active = false
          timer:stop()
          timer:close()
        end,
      }
    end,
  }
end

return M
