local fixtures = require("tests.helpers.performance_fixtures")
local filesystem = require("partial_completion.providers.filesystem")
local matcher = require("partial_completion.matcher")

local profiler
local profile_path = vim.env.PARTIAL_COMPLETION_PROFILE
if profile_path ~= nil and profile_path ~= "" and jit ~= nil then
  profiler = require("jit.p")
  profiler.start("fl", profile_path)
end

local function percentile(values, fraction)
  local ordered = {}
  for index, value in ipairs(values) do
    ordered[index] = value
  end
  table.sort(ordered)
  local index = math.max(1, math.ceil(#ordered * fraction))
  return ordered[index]
end

local function measure(callback, iterations)
  local values = {}
  for index = 1, iterations do
    local started = vim.uv.hrtime()
    callback()
    values[index] = (vim.uv.hrtime() - started) / 1e6
  end
  return values
end

local function measure_cpu(callback, iterations)
  local values = {}
  for index = 1, iterations do
    local started = os.clock()
    callback()
    values[index] = (os.clock() - started) * 1000
  end
  return values
end

local function allocated(callback)
  collectgarbage("collect")
  local before = collectgarbage("count")
  collectgarbage("stop")
  local ok, result = xpcall(callback, debug.traceback)
  local consumed = math.max(0, collectgarbage("count") - before)
  collectgarbage("restart")
  collectgarbage("collect")
  if not ok then
    error(result, 0)
  end
  return consumed, result
end

local function run_provider(provider, request, timeout)
  local result = {
    items = {},
    updates = 0,
    incomplete = false,
    ticks = 0,
    max_block_ms = 0,
  }
  local started = vim.uv.hrtime()
  local last_tick = started
  local heartbeat = assert(vim.uv.new_timer())
  heartbeat:start(0, 1, function()
    local now = vim.uv.hrtime()
    result.max_block_ms = math.max(result.max_block_ms, (now - last_tick) / 1e6)
    last_tick = now
    result.ticks = result.ticks + 1
  end)

  local provider_ok, handle_or_error = pcall(provider.complete, request, function(items, metadata)
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
    if result.first_ms == nil and #items > 0 then
      result.first_ms = (vim.uv.hrtime() - started) / 1e6
    end
  end, function(err)
    result.error = err
    result.complete_ms = (vim.uv.hrtime() - started) / 1e6
  end)

  local completed = provider_ok and vim.wait(timeout or 5000, function()
    return result.complete_ms ~= nil
  end, 1)
  local finished_at = vim.uv.hrtime()
  result.max_block_ms = math.max(result.max_block_ms, (finished_at - last_tick) / 1e6)
  heartbeat:stop()
  heartbeat:close()
  if (not provider_ok or not completed or result.error ~= nil) and type(handle_or_error) == "table" then
    pcall(handle_or_error.cancel, handle_or_error)
  end
  assert(provider_ok, handle_or_error)
  assert(completed, "provider benchmark timed out")
  assert(result.error == nil, result.error and result.error.message or "provider failed")
  return result
end

local function provider_series(provider, request, iterations, timeout)
  local results = {}
  for index = 1, iterations do
    results[index] = run_provider(provider, request, timeout)
  end
  local first = {}
  local complete = {}
  local block = {}
  for index, result in ipairs(results) do
    first[index] = assert(result.first_ms, "provider emitted no useful result")
    complete[index] = result.complete_ms
    block[index] = result.max_block_ms
  end
  return {
    results = results,
    first_p50 = percentile(first, 0.50),
    first_p95 = percentile(first, 0.95),
    complete_p50 = percentile(complete, 0.50),
    complete_p95 = percentile(complete, 0.95),
    block_p95 = percentile(block, 0.95),
  }
end

local commands = {}
for index = 1, 2000 do
  commands[index] = {
    id = string.format("command-%04d", index),
    text = string.format("TelescopeCommand%04dFindFiles", index),
    source_order = index,
  }
end

local command_profile = {
  category = "command",
  case_mode = "smart",
  allow_subsequence = false,
}

collectgarbage("collect")
local cold_started = os.clock()
local cold_ranked = matcher.rank("tcff", commands, command_profile)
local cold_ms = (os.clock() - cold_started) * 1000
assert(#cold_ranked == #commands)

matcher.rank("tcff", commands, command_profile)
local rank_times = measure_cpu(function()
  local ranked = matcher.rank("tcff", commands, command_profile)
  assert(#ranked == #commands)
end, 20)
local ordinary_times = measure_cpu(function()
  local ordinary = {}
  for index = 1, 600 do
    ordinary[index] = commands[index]
  end
  assert(#matcher.rank("tcff", ordinary, command_profile) == #ordinary)
end, 20)
local batch_times = measure_cpu(function()
  for _ = 1, 1000 do
    assert(matcher.match("te-fi-fi", "TelescopeFindFiles", command_profile))
  end
end, 20)
local rank_allocated_kb = allocated(function()
  assert(#matcher.rank("tcff", commands, command_profile) == #commands)
end)

local rank_p50 = percentile(rank_times, 0.50)
local rank_p95 = percentile(rank_times, 0.95)
local ordinary_p50 = percentile(ordinary_times, 0.50)
local ordinary_p95 = percentile(ordinary_times, 0.95)
local batch_p50 = percentile(batch_times, 0.50)
local batch_p95 = percentile(batch_times, 0.95)

local heartbeat_probe = run_provider({
  complete = function(_, emit, done)
    emit({ { id = "probe", label = "probe", insert_text = "probe" } })
    local deadline = vim.uv.hrtime() + 40 * 1000000
    while vim.uv.hrtime() < deadline do
    end
    done(nil)
    return { cancel = function() end }
  end,
}, { category = "generic", query = "probe" }, 1000)
assert(heartbeat_probe.max_block_ms >= 35, "heartbeat probe did not detect terminal synchronous blocking")

local fixture
local ok, benchmark_error = xpcall(function()
  fixture = fixtures.create({ large_count = 4096 })

  local path_provider = filesystem.new({
    case_sensitive = false,
    cache = { max_entries = 32, max_bytes = 8 * 1024 * 1024, ttl_ms = 60000 },
  })
  local path_request = {
    category = "path",
    query = "~/de/li",
    cwd = fixture.root,
    case_mode = "filesystem",
    limit = 20,
    context = { home = fixture.home },
  }
  local path_cold = run_provider(path_provider, path_request, 1000)
  assert(#path_cold.items == 2)
  local path_warm = provider_series(path_provider, path_request, 20, 1000)
  local path_cache_stats = path_provider.cache_stats()

  local deep_parts = { "de" }
  for _ = 1, 12 do
    deep_parts[#deep_parts + 1] = "se"
  end
  deep_parts[#deep_parts + 1] = "te"
  local qualification_requests = {
    {
      category = "path",
      query = table.concat(deep_parts, "/"),
      cwd = fixture.root,
      case_mode = "insensitive",
      limit = 20,
    },
    {
      category = "path",
      query = "un/Да/él/ca",
      cwd = fixture.root,
      case_mode = "insensitive",
      limit = 20,
    },
  }
  assert(fixture.has_symlink, "symlink qualification is required on the macOS/Linux benchmark gate")
  qualification_requests[#qualification_requests + 1] = {
    category = "path",
    query = "li/Li/li",
    cwd = fixture.root,
    case_mode = "insensitive",
    limit = 20,
  }
  for _, qualification_request in ipairs(qualification_requests) do
    local series = provider_series(path_provider, qualification_request, 5, 2000)
    for _, result in ipairs(series.results) do
      assert(#result.items == 1, "deep/Unicode/symlink qualification produced the wrong result count")
    end
    assert(series.complete_p95 <= 250, "deep/Unicode/symlink qualification exceeded 250ms p95")
    assert(series.block_p95 <= 50, "deep/Unicode/symlink qualification blocked the event loop")
  end

  local large_provider = filesystem.new({
    scan_chunk_size = 256,
    emit_chunk_size = 32,
    case_sensitive = false,
    cache = { max_entries = 16, max_bytes = 8 * 1024 * 1024, ttl_ms = 60000 },
  })
  local large_request = {
    category = "path",
    query = "large-flat/ic",
    cwd = fixture.root,
    case_mode = "filesystem",
    limit = 100,
  }
  local large_cold = run_provider(large_provider, large_request, 10000)
  local large_warm = provider_series(large_provider, large_request, 10, 10000)
  local large_allocated_kb, large_allocated_run = allocated(function()
    return run_provider(large_provider, large_request, 10000)
  end)
  local large_cache_stats = large_provider.cache_stats()
  local expected_large_ids = vim.tbl_map(function(item)
    return item.id
  end, large_cold.items)
  local function assert_large_result(result, label)
    assert(#result.items == 100, label .. " returned the wrong item count")
    assert(result.incomplete, label .. " lost truncation metadata")
    assert(result.updates >= 2, label .. " did not stream before completion")
    assert(result.first_ms < result.complete_ms, label .. " published no useful pre-terminal update")
    assert(
      vim.deep_equal(
        vim.tbl_map(function(item)
          return item.id
        end, result.items),
        expected_large_ids
      ),
      label .. " changed the final IDs/order"
    )
  end
  assert_large_result(large_cold, "large-flat cold run")
  for index, result in ipairs(large_warm.results) do
    assert_large_result(result, "large-flat warm run " .. index)
  end
  assert_large_result(large_allocated_run, "large-flat allocation run")

  local directory_request = {
    category = "path",
    query = "directory-only/entry-t",
    cwd = fixture.root,
    case_mode = "sensitive",
    limit = 5,
    context = { only_directories = true },
  }
  local function qualify_directory_only(provider, label, request, prime)
    prime()
    local before = provider.cache_stats().stat_calls
    local series = provider_series(provider, request, 5, 2000)
    local stats = provider.cache_stats()
    for _, result in ipairs(series.results) do
      assert(#result.items == 2, label .. " returned the wrong directory count")
      assert(result.items[1].kind == "directory" and result.items[2].kind == "directory")
    end
    return {
      series = series,
      stat_calls = stats.stat_calls - before,
      max_concurrent_stats = stats.max_concurrent_stats,
    }
  end

  local directory_provider = filesystem.new({
    case_sensitive = true,
    cache = { max_entries = 16, max_bytes = 1024 * 1024, ttl_ms = 60000 },
  })
  local directory_only = qualify_directory_only(
    directory_provider,
    "cached directory-only",
    directory_request,
    function()
      run_provider(directory_provider, {
        category = "path",
        query = "directory-only/entry-",
        cwd = fixture.root,
        case_mode = "sensitive",
        limit = 400,
      }, 5000)
    end
  )

  local unknown_provider = filesystem.new({
    case_sensitive = true,
    cache = { max_entries = 16, max_bytes = 1024 * 1024, ttl_ms = 60000 },
  })
  local directory_unknown = qualify_directory_only(
    unknown_provider,
    "unknown d_type directory-only",
    directory_request,
    function()
      local original_scandir_next = vim.uv.fs_scandir_next
      local patched_ok, patched_error = xpcall(function()
        vim.uv.fs_scandir_next = function(scan)
          local name = original_scandir_next(scan)
          return name, nil
        end
        run_provider(unknown_provider, directory_request, 5000)
      end, debug.traceback)
      vim.uv.fs_scandir_next = original_scandir_next
      assert(patched_ok, patched_error)
    end
  )

  assert(fixture.has_symlink_heavy, "symlink-heavy qualification is required on the benchmark gate")
  local symlink_provider = filesystem.new({
    case_sensitive = true,
    cache = { max_entries = 16, max_bytes = 1024 * 1024, ttl_ms = 60000 },
  })
  local symlink_request = vim.tbl_deep_extend("force", {}, directory_request, {
    query = "symlink-heavy/dir-link-",
    limit = 2,
  })
  local symlink_only = qualify_directory_only(
    symlink_provider,
    "symlink-heavy directory-only",
    symlink_request,
    function()
      run_provider(symlink_provider, {
        category = "path",
        query = "symlink-heavy/",
        cwd = fixture.root,
        case_mode = "sensitive",
        limit = 100,
      }, 5000)
    end
  )

  local slow_series = provider_series(fixtures.slow_provider(10, 4), {
    category = "generic",
    query = "slow",
  }, 5, 1000)
  local slow_min_ticks = math.huge
  for _, result in ipairs(slow_series.results) do
    assert(#result.items == 4)
    slow_min_ticks = math.min(slow_min_ticks, result.ticks)
  end

  local native_query = fixture.large_flat .. "/ic"
  local native_count = 0
  local native_times = measure(function()
    local items = vim.fn.getcompletion(native_query, "file", false)
    native_count = #items
  end, 5)

  local blink_summary
  local dependencies = assert(vim.env.PARTIAL_COMPLETION_DEPS_DIR, "adapter dependency root is unavailable")
  local blink_root = dependencies .. "/blink.cmp"
  assert(vim.fn.isdirectory(blink_root) == 1, "pinned Blink dependency is unavailable")
  do
    local blink_ok, blink_result = pcall(function()
      vim.opt.runtimepath:prepend(blink_root)
      local source = require("blink.cmp.sources.path").new({
        get_cwd = function()
          return fixture.root
        end,
        max_entries = fixture.large_count + 10,
      })
      local line = fixture.large_flat .. "/ic"
      local start_col = #fixture.large_flat + 2
      local blink_times = {}
      local count = 0
      for index = 1, 5 do
        local completed = false
        local started = vim.uv.hrtime()
        source:get_completions({
          mode = "default",
          id = index,
          bufnr = vim.api.nvim_get_current_buf(),
          cursor = { 1, #line },
          line = line,
          bounds = {
            line = line,
            line_number = 1,
            start_col = start_col,
            length = 2,
          },
        }, function(response)
          count = response and response.items and #response.items or 0
          blink_times[index] = (vim.uv.hrtime() - started) / 1e6
          completed = true
        end)
        assert(vim.wait(10000, function()
          return completed
        end, 1))
      end
      return string.format(
        "entries=%d warm-p50=%.3fms warm-p95=%.3fms",
        count,
        percentile(blink_times, 0.50),
        percentile(blink_times, 0.95)
      )
    end)
    assert(blink_ok, blink_result)
    blink_summary = blink_result
  end

  local finder_started = vim.uv.hrtime()
  local finder_result = vim.system({ "find", fixture.large_flat, "-type", "f", "-print" }, { text = true }):wait()
  local finder_ms = (vim.uv.hrtime() - finder_started) / 1e6
  assert(finder_result.code == 0)
  local finder_count = 0
  for _ in string.gmatch(finder_result.stdout or "", "[^\n]+") do
    finder_count = finder_count + 1
  end

  local version = vim.version()
  print(
    string.format(
      "environment: Neovim %d.%d.%d, %s, %s",
      version.major,
      version.minor,
      version.patch,
      jit and jit.version or _VERSION,
      vim.uv.os_uname().sysname
    )
  )
  print(
    string.format(
      "filesystem-directory-only: cached-first-p95=%.3fms cached-complete-p95=%.3fms cached-stat-calls=%d; "
        .. "unknown-first-p95=%.3fms unknown-complete-p95=%.3fms unknown-stat-calls=%d; "
        .. "symlink-first-p95=%.3fms symlink-complete-p95=%.3fms symlink-stat-calls=%d max-concurrent=%d",
      directory_only.series.first_p95,
      directory_only.series.complete_p95,
      directory_only.stat_calls,
      directory_unknown.series.first_p95,
      directory_unknown.series.complete_p95,
      directory_unknown.stat_calls,
      symlink_only.series.first_p95,
      symlink_only.series.complete_p95,
      symlink_only.stat_calls,
      math.max(
        directory_only.max_concurrent_stats,
        directory_unknown.max_concurrent_stats,
        symlink_only.max_concurrent_stats
      )
    )
  )
  print(
    string.format(
      "filesystem-~/de/li: results=2 cold-first=%.3fms cold-complete=%.3fms "
        .. "warm-first-p50=%.3fms warm-first-p95=%.3fms warm-complete-p50=%.3fms warm-complete-p95=%.3fms "
        .. "runs=%d cache-hits=%d cache-misses=%d",
      path_cold.first_ms,
      path_cold.complete_ms,
      path_warm.first_p50,
      path_warm.first_p95,
      path_warm.complete_p50,
      path_warm.complete_p95,
      #path_warm.results,
      path_cache_stats.hits,
      path_cache_stats.misses
    )
  )
  print(
    string.format(
      "filesystem-large-flat: entries=%d limit=100 cold-first=%.3fms cold-complete=%.3fms "
        .. "warm-first-p50=%.3fms warm-first-p95=%.3fms warm-complete-p50=%.3fms warm-complete-p95=%.3fms "
        .. "warm-block-p95=%.3fms allocated=%.1fKiB updates=%d runs=%d cache-hits=%d cache-misses=%d",
      fixture.large_count,
      large_cold.first_ms,
      large_cold.complete_ms,
      large_warm.first_p50,
      large_warm.first_p95,
      large_warm.complete_p50,
      large_warm.complete_p95,
      large_warm.block_p95,
      large_allocated_kb,
      large_cold.updates,
      #large_warm.results,
      large_cache_stats.hits,
      large_cache_stats.misses
    )
  )
  print(
    string.format(
      "rank-2000-cpu: candidates=%d cold=%.3fms warm-p50=%.3fms warm-p95=%.3fms allocated=%.1fKiB runs=%d",
      #commands,
      cold_ms,
      rank_p50,
      rank_p95,
      rank_allocated_kb,
      #rank_times
    )
  )
  print(
    string.format(
      "rank-600-cpu: candidates=600 warm-p50=%.3fms warm-p95=%.3fms runs=%d",
      ordinary_p50,
      ordinary_p95,
      #ordinary_times
    )
  )
  print(
    string.format(
      "structured-1000-cpu: operations=1000 warm-p50=%.3fms warm-p95=%.3fms runs=%d",
      batch_p50,
      batch_p95,
      #batch_times
    )
  )
  print(
    string.format(
      "simulated-slow: chunks=4 first-p95=%.3fms complete-p95=%.3fms "
        .. "heartbeat-ticks-min=%d max-block-p95=%.3fms runs=%d",
      slow_series.first_p95,
      slow_series.complete_p95,
      slow_min_ticks,
      slow_series.block_p95,
      #slow_series.results
    )
  )
  print(
    string.format(
      "comparison-literal-final-dir: native-results=%d native-p50=%.3fms native-p95=%.3fms; blink=%s; "
        .. "recursive-find-backend-results=%d recursive-enumeration=%.3fms; recorded-emacs-partial=0.830ms",
      native_count,
      percentile(native_times, 0.50),
      percentile(native_times, 0.95),
      blink_summary,
      finder_count,
      finder_ms
    )
  )

  local failures = {}
  if rank_p95 > 75 then
    failures[#failures + 1] = string.format("rank-2000 CPU p95 %.3fms exceeds 75ms", rank_p95)
  end
  if ordinary_p95 > 30 then
    failures[#failures + 1] = string.format("rank-600 CPU p95 %.3fms exceeds 30ms", ordinary_p95)
  end
  if batch_p95 > 30 then
    failures[#failures + 1] = string.format("structured-1000 CPU p95 %.3fms exceeds 30ms", batch_p95)
  end
  if path_warm.first_p95 > 8 then
    failures[#failures + 1] = string.format("filesystem warm first-result p95 %.3fms exceeds 8ms", path_warm.first_p95)
  end
  if path_warm.complete_p95 > 16 then
    failures[#failures + 1] =
      string.format("filesystem warm completion p95 %.3fms exceeds 16ms", path_warm.complete_p95)
  end
  if path_cache_stats.hits < 20 then
    failures[#failures + 1] = string.format("filesystem warm cache hits %d are below 20", path_cache_stats.hits)
  end
  if large_cold.first_ms > 150 then
    failures[#failures + 1] = string.format("large-flat cold first-result %.3fms exceeds 150ms", large_cold.first_ms)
  end
  if large_warm.first_p95 > 75 then
    failures[#failures + 1] =
      string.format("large-flat warm first-result p95 %.3fms exceeds 75ms", large_warm.first_p95)
  end
  if large_warm.complete_p95 > 2000 then
    failures[#failures + 1] =
      string.format("large-flat warm completion p95 %.3fms exceeds 2000ms", large_warm.complete_p95)
  end
  if large_warm.block_p95 > 50 then
    failures[#failures + 1] = string.format("large-flat event-loop block p95 %.3fms exceeds 50ms", large_warm.block_p95)
  end
  if large_allocated_kb > 32 * 1024 then
    failures[#failures + 1] = string.format("large-flat warm allocation %.1fKiB exceeds 32768KiB", large_allocated_kb)
  end
  if large_cold.updates < 2 or large_cold.first_ms >= large_cold.complete_ms then
    failures[#failures + 1] = "large-flat completion did not publish before terminal completion"
  end
  for _, case in ipairs({
    { "cached", directory_only },
    { "unknown", directory_unknown },
    { "symlink", symlink_only },
  }) do
    local label, qualification = case[1], case[2]
    if qualification.series.first_p95 > 8 then
      failures[#failures + 1] =
        string.format("%s directory-only first-result p95 %.3fms exceeds 8ms", label, qualification.series.first_p95)
    end
    if qualification.series.complete_p95 > 30 then
      failures[#failures + 1] =
        string.format("%s directory-only completion p95 %.3fms exceeds 30ms", label, qualification.series.complete_p95)
    end
    if qualification.stat_calls > 40 then
      failures[#failures + 1] =
        string.format("%s directory-only used %d stat calls across 5 warm runs", label, qualification.stat_calls)
    end
    if qualification.max_concurrent_stats < 2 then
      failures[#failures + 1] = label .. " directory-only validation never ran concurrently"
    end
  end
  if slow_min_ticks < 20 or slow_series.block_p95 > 25 or slow_series.complete_p95 > 100 then
    failures[#failures + 1] = string.format(
      "simulated-slow responsiveness ticks=%d max-block-p95=%.3fms complete-p95=%.3fms is outside budget",
      slow_min_ticks,
      slow_series.block_p95,
      slow_series.complete_p95
    )
  end
  if #failures > 0 then
    error(table.concat(failures, "\n"))
  end

  print("Matcher and filesystem performance qualification thresholds passed")
end, debug.traceback)

fixtures.destroy(fixture)
if profiler ~= nil then
  profiler.stop()
end
if not ok then
  error(benchmark_error, 0)
end
