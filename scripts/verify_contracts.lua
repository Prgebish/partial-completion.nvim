local cases = dofile("tests/contract/cases.lua")

local failures = {}
local ids = {}

local function fail(message)
  failures[#failures + 1] = message
end

local function check(condition, message)
  if not condition then
    fail(message)
  end
end

local function boundary(text, position)
  if position == 0 or position == #text then
    return true
  end

  local byte = string.byte(text, position + 1)
  return byte == nil or byte < 128 or byte > 191
end

local function register(group, case)
  check(type(case.id) == "string" and case.id ~= "", group .. " case without id")
  if type(case.id) == "string" then
    check(ids[case.id] == nil, "duplicate case id: " .. case.id)
    ids[case.id] = group
  end
end

local expected_categories = {
  "path",
  "command",
  "option",
  "buffer",
  "help",
  "function",
  "variable",
  "mapping",
  "generic",
}

check(cases.api_version == 1, "contract api_version must be 1")
check(#cases.categories == #expected_categories, "category count changed")

local category_set = {}
for index, category in ipairs(cases.categories) do
  check(category == expected_categories[index], "category order or spelling changed at index " .. index)
  category_set[category] = true
end

local covered_categories = {}
for _, case in ipairs(cases.matcher) do
  register("matcher", case)
  check(category_set[case.category] == true, "unknown matcher category in " .. case.id)
  covered_categories[case.category] = true
  check(type(case.query) == "string", "matcher query must be a string in " .. case.id)
  check(type(case.candidate) == "string", "matcher candidate must be a string in " .. case.id)
  check(type(case.expected) == "table", "matcher expected result missing in " .. case.id)

  if case.expected and case.expected.matched then
    check(type(case.expected.level) == "string", "matched case missing level in " .. case.id)
    check(type(case.expected.spans) == "table", "matched case missing spans in " .. case.id)
    local previous_end = 0
    for _, span in ipairs(case.expected.spans or {}) do
      local start_byte = span[1]
      local end_byte = span[2]
      check(type(start_byte) == "number" and type(end_byte) == "number", "non-numeric span in " .. case.id)
      if type(start_byte) == "number" and type(end_byte) == "number" then
        check(start_byte >= previous_end, "unordered or overlapping spans in " .. case.id)
        check(start_byte < end_byte and end_byte <= #case.candidate, "out-of-range span in " .. case.id)
        check(boundary(case.candidate, start_byte), "span starts inside UTF-8 code point in " .. case.id)
        check(boundary(case.candidate, end_byte), "span ends inside UTF-8 code point in " .. case.id)
        previous_end = end_byte
      end
    end
  end
end

for _, category in ipairs(expected_categories) do
  check(covered_categories[category] == true, "no matcher case for category: " .. category)
end

for _, case in ipairs(cases.ranking) do
  register("ranking", case)
  check(#case.candidates == #case.expected_ids, "ranking result length mismatch in " .. case.id)
  local candidate_ids = {}
  for _, candidate in ipairs(case.candidates) do
    check(candidate_ids[candidate.id] == nil, "duplicate candidate id in " .. case.id)
    candidate_ids[candidate.id] = true
  end
  for _, id in ipairs(case.expected_ids) do
    check(candidate_ids[id] == true, "ranking expects unknown id " .. tostring(id) .. " in " .. case.id)
  end
end

for _, case in ipairs(cases.replacements) do
  register("replacement", case)
  local range = case.replacement
  check(range.start_byte >= 0, "negative replacement start in " .. case.id)
  check(range.start_byte <= range.end_byte, "inverted replacement in " .. case.id)
  check(range.start_byte <= case.cursor_byte, "native replacement starts after cursor in " .. case.id)
  check(range.end_byte >= case.cursor_byte, "native replacement ends before cursor in " .. case.id)
  check(range.end_byte <= #case.source_text, "replacement exceeds source text in " .. case.id)
  check(boundary(case.source_text, range.start_byte), "replacement starts inside UTF-8 code point in " .. case.id)
  check(boundary(case.source_text, case.cursor_byte), "cursor splits a UTF-8 code point in " .. case.id)
  check(boundary(case.source_text, range.end_byte), "replacement ends inside UTF-8 code point in " .. case.id)

  local actual = string.sub(case.source_text, 1, range.start_byte)
    .. case.insert_text
    .. string.sub(case.source_text, range.end_byte + 1)
  check(actual == case.expected_text, "replacement output mismatch in " .. case.id)
  check(range.start_byte + #case.insert_text == case.expected_cursor_byte, "replacement cursor mismatch in " .. case.id)
end

for _, case in ipairs(cases.paths) do
  register("path", case)
  check(type(case.input) == "string", "path input missing in " .. case.id)
  check(type(case.context) == "table", "path context missing in " .. case.id)
  check(case.expected.status == "ok" or case.expected.status == "error", "invalid path status in " .. case.id)
  if case.expected.status == "ok" then
    check(type(case.expected.root_text) == "string", "path root_text missing in " .. case.id)
    check(type(case.expected.scan_root) == "string", "path scan_root missing in " .. case.id)
    check(type(case.expected.remainder) == "string", "path remainder missing in " .. case.id)
  else
    check(type(case.expected.error_code) == "string", "path error code missing in " .. case.id)
    check(case.expected.original == case.input, "unsupported path must preserve original in " .. case.id)
  end
end

for _, case in ipairs(cases.path_resolution) do
  register("path_resolution", case)
  check(type(case.expected_insert_text) == "string", "path resolution insertion missing in " .. case.id)
  check(type(case.expected_physical_suffix) == "string", "path resolution physical suffix missing in " .. case.id)
end

for _, case in ipairs(cases.api) do
  register("api", case)
  check(type(case.provider_name) == "string", "api provider name missing in " .. case.id)
  check(type(case.request) == "table", "api request missing in " .. case.id)
  check(type(case.chunks) == "table" and #case.chunks > 0, "api chunks missing in " .. case.id)
  check(case.expected.api_version == 1, "api expected version changed in " .. case.id)
  check(case.expected.terminal_count == 1, "api terminal count must be one in " .. case.id)
end

for _, case in ipairs(cases.sessions) do
  register("session", case)
  check(type(case.expected) == "string", "session expectation missing in " .. case.id)
end

check(#cases.matcher >= 20, "matcher corpus unexpectedly shrank")
check(#cases.ranking >= 6, "ranking corpus unexpectedly shrank")
check(#cases.replacements >= 5, "replacement corpus unexpectedly shrank")
check(#cases.paths >= 11, "path-root corpus unexpectedly shrank")
check(#cases.path_resolution >= 1, "path-resolution corpus unexpectedly shrank")
check(#cases.api >= 1, "public API corpus unexpectedly shrank")
check(#cases.sessions >= 4, "session corpus unexpectedly shrank")

if #failures > 0 then
  for _, message in ipairs(failures) do
    io.stderr:write("contract error: " .. message .. "\n")
  end
  os.exit(1)
end

local total = #cases.matcher
  + #cases.ranking
  + #cases.replacements
  + #cases.paths
  + #cases.path_resolution
  + #cases.api
  + #cases.sessions

io.stdout:write(string.format("Phase 1 contract corpus valid: %d executable cases\n", total))
