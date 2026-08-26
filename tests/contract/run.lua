-- This runner is intentionally red until the owning runtime phases implement
-- the required modules. make verify validates the corpus, while future phases
-- add each group to the aggregate gate as its implementation lands.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local cases = dofile("tests/contract/cases.lua")
local requested_group = arg and arg[1] or "all"
local failures = {}

local function equal(actual, expected, context)
  if vim.deep_equal(actual, expected) then
    return
  end
  failures[#failures + 1] = context
    .. "\n  expected: "
    .. vim.inspect(expected)
    .. "\n  actual:   "
    .. vim.inspect(actual)
end

local function selected(group)
  return requested_group == "all" or requested_group == group
end

local function run_matcher()
  local matcher = require("partial_completion.matcher")

  for _, case in ipairs(cases.matcher) do
    local actual = matcher.match(case.query, case.candidate, {
      category = case.category,
      case_mode = case.case_mode,
      matching_style = case.matching_style,
      allow_subsequence = case.allow_subsequence == true,
    })

    if case.expected.matched then
      equal(actual and {
        matched = true,
        level = actual.level,
        spans = actual.spans,
      } or { matched = false }, case.expected, "matcher: " .. case.id)
    else
      equal(actual == nil and { matched = false } or { matched = true }, case.expected, "matcher: " .. case.id)
    end
  end

  for _, case in ipairs(cases.ranking) do
    local ranked = matcher.rank(case.query, case.candidates, {
      category = case.category,
      case_mode = case.case_mode,
      matching_style = case.matching_style,
    })
    local ids = {}
    for _, item in ipairs(ranked) do
      ids[#ids + 1] = item.id
    end
    equal(ids, case.expected_ids, "ranking: " .. case.id)
  end
end

local function run_replacements()
  local cmdline = require("partial_completion.cmdline")

  for _, case in ipairs(cases.replacements) do
    local text, cursor = cmdline.apply_edit(case.source_text, case.replacement, case.insert_text)
    equal({ text = text, cursor_byte = cursor }, {
      text = case.expected_text,
      cursor_byte = case.expected_cursor_byte,
    }, "replacement: " .. case.id)
  end
end

local function run_paths()
  local filesystem = require("partial_completion.providers.filesystem")

  for _, case in ipairs(cases.paths) do
    equal(filesystem.parse_root(case.input, case.context), case.expected, "path: " .. case.id)
  end

  for _, case in ipairs(cases.path_resolution) do
    local root = vim.fn.tempname()
    local home = root .. "/home"
    local target = root .. "/" .. case.fixture.target_name
    local link = home .. "/" .. case.fixture.link_name
    local file = target .. "/" .. case.fixture.file_name
    vim.fn.mkdir(home, "p")
    vim.fn.mkdir(target, "p")
    vim.fn.writefile({ "contract fixture" }, file)
    assert(vim.uv.fs_symlink(target, link, { dir = true }))

    local items = {}
    local done = false
    local completion_error
    local handle = filesystem.complete({
      api_version = 1,
      category = "path",
      query = case.input,
      cwd = root,
      case_mode = "sensitive",
      context = { home = home },
    }, function(chunk)
      for _, item in ipairs(chunk) do
        items[#items + 1] = item
      end
    end, function(err)
      completion_error = err
      done = true
    end)

    local completed = vim.wait(1000, function()
      return done
    end, 5)
    if not completed and handle then
      handle:cancel()
    end

    equal(completed, true, "path resolution timeout: " .. case.id)
    equal(completion_error, nil, "path resolution error: " .. case.id)
    equal(items[1] and items[1].insert_text, case.expected_insert_text, "path resolution insertion: " .. case.id)
    local physical_path = items[1] and items[1].data and items[1].data.path
    equal(physical_path, root .. case.expected_physical_suffix, "path resolution physical path: " .. case.id)
    vim.fn.delete(root, "rf")
  end
end

local function run_sessions()
  local session = require("partial_completion.session")

  for _, case in ipairs(cases.sessions) do
    equal(session.contract_decision(case), case.expected, "session: " .. case.id)
  end
end

local function run_api()
  local completion = require("partial_completion")

  for _, case in ipairs(cases.api) do
    completion.setup({})
    completion.register_provider(case.provider_name, {
      api_version = 1,
      categories = { case.request.category },
      complete = function(_, emit, done)
        for _, chunk in ipairs(case.chunks) do
          emit(chunk, { is_incomplete = false })
        end
        done(nil)
        return {
          cancel = function() end,
        }
      end,
    }, { replace = true })

    local updates = {}
    local handle = completion.complete(case.request, function(update)
      updates[#updates + 1] = update
    end)

    vim.wait(1000, function()
      return updates[#updates] and updates[#updates].done
    end, 5)

    local terminal_count = 0
    for _, update in ipairs(updates) do
      if update.done then
        terminal_count = terminal_count + 1
      end
    end

    local final = updates[#updates]
    local final_ids = {}
    for _, item in ipairs(final and final.items or {}) do
      final_ids[#final_ids + 1] = item.id
    end
    equal(completion.api_version, case.expected.api_version, "api version: " .. case.id)
    equal(final_ids, case.expected.final_ids, "api final items: " .. case.id)
    equal(terminal_count, case.expected.terminal_count, "api terminal count: " .. case.id)
    handle:cancel()
    handle:cancel()
  end
end

local runners = {
  api = run_api,
  matcher = run_matcher,
  replacement = run_replacements,
  path = run_paths,
  session = run_sessions,
}

if requested_group ~= "all" and runners[requested_group] == nil then
  error("unknown contract group: " .. tostring(requested_group))
end

for _, group in ipairs({ "api", "matcher", "replacement", "path", "session" }) do
  if selected(group) then
    runners[group]()
  end
end

if #failures > 0 then
  error(table.concat(failures, "\n"))
end

print("Phase 1 executable behavior contract passed: " .. requested_group)
