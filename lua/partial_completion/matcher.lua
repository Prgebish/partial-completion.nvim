local boundaries = require("partial_completion.boundaries")
local utf8 = require("partial_completion.utf8")

local M = {}

local level_rank = {
  exact = 6,
  prefix = 5,
  component_prefix = 4,
  word_prefix = 3,
  initials = 2,
  subsequence = 1,
}

local function path_children_query(query, profile_name, separator_mode)
  local trailing = string.sub(query, -1)
  return profile_name == "path" and #query > 0 and (trailing == "/" or (separator_mode == "both" and trailing == "\\"))
end

local function character_count(text, known_ascii)
  if known_ascii then
    return #text
  end
  return #utf8.chars(text)
end

local function effective_sensitive(query, case_mode)
  if case_mode == "sensitive" then
    return true
  end
  if case_mode == "insensitive" then
    return false
  end
  if case_mode == "filesystem" then
    return true
  end
  return utf8.has_upper(query)
end

local function characters_match(query_character, candidate_character, sensitive)
  if query_character == candidate_character then
    return true, 0
  end
  if sensitive then
    return false, 0
  end
  return utf8.lower(query_character) == utf8.lower(candidate_character), 1
end

local function prefix_match(query, candidate, sensitive, known_ascii)
  if known_ascii or (utf8.is_ascii(query) and utf8.is_ascii(candidate)) then
    if #query > #candidate then
      return nil
    end
    local case_mismatches = 0
    for index = 1, #query do
      local query_byte = string.byte(query, index)
      local candidate_byte = string.byte(candidate, index)
      if query_byte ~= candidate_byte then
        if sensitive then
          return nil
        end
        local folded_query = query_byte >= 0x41 and query_byte <= 0x5A and query_byte + 0x20 or query_byte
        local folded_candidate = candidate_byte >= 0x41 and candidate_byte <= 0x5A and candidate_byte + 0x20
          or candidate_byte
        if folded_query ~= folded_candidate then
          return nil
        end
        case_mismatches = case_mismatches + 1
      end
    end
    return {
      case_mismatches = case_mismatches,
      end_byte = #query,
      query_characters = #query,
      candidate_characters = #candidate,
    }
  end

  local query_characters = utf8.chars(query)
  local candidate_characters = utf8.chars(candidate)
  if query_characters == nil or candidate_characters == nil or #query_characters > #candidate_characters then
    return nil
  end

  local case_mismatches = 0
  local end_byte = 0
  for index, query_character in ipairs(query_characters) do
    local candidate_character = candidate_characters[index]
    local matches, mismatch = characters_match(query_character.text, candidate_character.text, sensitive)
    if not matches then
      return nil
    end
    case_mismatches = case_mismatches + mismatch
    end_byte = candidate_character.end_byte
  end

  return {
    case_mismatches = case_mismatches,
    end_byte = end_byte,
    query_characters = #query_characters,
    candidate_characters = #candidate_characters,
  }
end

local result
local better_state
local shifted_spans
local append_spans

local emacs_separators = {
  ["-"] = true,
  ["_"] = true,
  ["."] = true,
  ["/"] = true,
  [":"] = true,
  ["|"] = true,
}

local function emacs_separator(character)
  return emacs_separators[character] == true
    or character == " "
    or character == "\t"
    or character == "\n"
    or character == "\r"
    or character == "\f"
    or character == "\v"
end

local function literal_at(query_characters, candidate_characters, candidate_index, sensitive)
  local spans = {}
  local case_mismatches = 0
  for query_index, query_character in ipairs(query_characters) do
    local candidate_character = candidate_characters[candidate_index + query_index - 1]
    if candidate_character == nil then
      return nil
    end
    local matches, mismatch = characters_match(query_character.text, candidate_character.text, sensitive)
    if not matches then
      return nil
    end
    spans[#spans + 1] = { candidate_character.start_byte, candidate_character.end_byte }
    case_mismatches = case_mismatches + mismatch
  end
  return {
    spans = spans,
    case_mismatches = case_mismatches,
    next_index = candidate_index + #query_characters,
  }
end

-- GNU Emacs compatibility is specified from black-box observations.  A star
-- separates literal chunks and may consume any number of characters, while a
-- match remains anchored at byte zero unless the pattern itself starts in '*'.
local function emacs_glob_prefix_match(pattern, candidate, sensitive)
  if not string.find(pattern, "*", 1, true) then
    local prefix = prefix_match(pattern, candidate, sensitive)
    if prefix == nil then
      return nil
    end
    return {
      spans = prefix.end_byte > 0 and { { 0, prefix.end_byte } } or {},
      case_mismatches = prefix.case_mismatches,
      end_byte = prefix.end_byte,
      wildcard = false,
    }
  end

  local candidate_characters = utf8.chars(candidate)
  if candidate_characters == nil then
    return nil
  end
  local chunks = {}
  local start_byte = 1
  while true do
    local star = string.find(pattern, "*", start_byte, true)
    chunks[#chunks + 1] = string.sub(pattern, start_byte, star and star - 1 or #pattern)
    if star == nil then
      break
    end
    start_byte = star + 1
  end

  local spans = {}
  local case_mismatches = 0
  local candidate_index = 1
  local leading_star = string.sub(pattern, 1, 1) == "*"
  for chunk_index, chunk in ipairs(chunks) do
    if chunk ~= "" then
      local query_characters = utf8.chars(chunk)
      if query_characters == nil then
        return nil
      end
      local found
      local first_index = candidate_index
      local last_index = #candidate_characters - #query_characters + 1
      if chunk_index == 1 and not leading_star then
        last_index = first_index
      end
      for index = first_index, last_index do
        found = literal_at(query_characters, candidate_characters, index, sensitive)
        if found ~= nil then
          break
        end
      end
      if found == nil then
        return nil
      end
      for _, span in ipairs(found.spans) do
        spans[#spans + 1] = span
      end
      case_mismatches = case_mismatches + found.case_mismatches
      candidate_index = found.next_index
    end
  end

  return {
    spans = utf8.coalesce_spans(spans),
    case_mismatches = case_mismatches,
    end_byte = spans[#spans] and spans[#spans][2] or 0,
    wildcard = true,
  }
end

local function emacs_words(text)
  local characters = utf8.chars(text)
  if characters == nil then
    return nil
  end
  local words = {}
  local separator_runs = {}
  local current_start
  local separator_count = 0

  local function finish_word(end_byte)
    if current_start == nil then
      return
    end
    words[#words + 1] = {
      start_byte = current_start,
      end_byte = end_byte,
      text = string.sub(text, current_start + 1, end_byte),
    }
    current_start = nil
  end

  for _, character in ipairs(characters) do
    if emacs_separator(character.text) then
      finish_word(character.start_byte)
      separator_count = separator_count + 1
    else
      if current_start == nil then
        if #words > 0 and separator_count > 0 then
          separator_runs[#separator_runs + 1] = separator_count
        end
        separator_count = 0
        current_start = character.start_byte
      end
    end
  end
  finish_word(#text)
  return words, separator_runs, #separator_runs > 0 or separator_count > 0
end

local function emacs_word_match(query, candidate, sensitive)
  if not string.find(query, "*", 1, true) then
    local prefix = prefix_match(query, candidate, sensitive)
    if prefix ~= nil then
      return result(
        prefix.query_characters == prefix.candidate_characters and "exact" or "prefix",
        prefix.end_byte > 0 and { { 0, prefix.end_byte } } or {},
        prefix.case_mismatches,
        0
      )
    end
  end

  local query_words, separator_runs, explicit = emacs_words(query)
  local candidate_words = emacs_words(candidate)
  if query_words == nil or candidate_words == nil or #query_words == 0 or #candidate_words == 0 then
    return nil
  end

  if not explicit then
    local glob = emacs_glob_prefix_match(query, candidate, sensitive)
    if glob == nil then
      return nil
    end
    local level = "prefix"
    if not glob.wildcard and glob.end_byte == #candidate then
      level = "exact"
    elseif glob.wildcard then
      level = "word_prefix"
    end
    return result(level, glob.spans, glob.case_mismatches, 0)
  end

  local states = {}
  for query_index, query_word in ipairs(query_words) do
    local next_states = {}
    for candidate_index, candidate_word in ipairs(candidate_words) do
      local glob = emacs_glob_prefix_match(query_word.text, candidate_word.text, sensitive)
      if glob ~= nil then
        if query_index == 1 and candidate_index == 1 then
          next_states[candidate_index] = {
            case_mismatches = glob.case_mismatches,
            skipped_bytes = 0,
            skipped_words = 0,
            first_start = candidate_word.start_byte,
            start_byte = candidate_word.start_byte,
            end_byte = candidate_word.start_byte + glob.end_byte,
            spans = shifted_spans(glob.spans, candidate_word.start_byte),
            path_key = string.format("%08d", candidate_index),
          }
        elseif query_index > 1 then
          local minimum_gap = math.max((separator_runs[query_index - 1] or 1) - 1, 0)
          for previous_index = 1, candidate_index - minimum_gap - 1 do
            local previous = states[previous_index]
            if previous ~= nil then
              local candidate_spans = {}
              append_spans(candidate_spans, previous.spans)
              append_spans(candidate_spans, shifted_spans(glob.spans, candidate_word.start_byte))
              local candidate_state = {
                case_mismatches = previous.case_mismatches + glob.case_mismatches,
                skipped_bytes = previous.skipped_bytes + candidate_word.start_byte - previous.end_byte,
                skipped_words = previous.skipped_words + candidate_index - previous_index - 1,
                first_start = previous.first_start,
                start_byte = candidate_word.start_byte,
                end_byte = candidate_word.start_byte + glob.end_byte,
                spans = candidate_spans,
                path_key = previous.path_key .. ":" .. string.format("%08d", candidate_index),
              }
              if better_state(candidate_state, next_states[candidate_index]) then
                next_states[candidate_index] = candidate_state
              end
            end
          end
        end
      end
    end
    states = next_states
  end

  local best
  for _, state in pairs(states) do
    if better_state(state, best) then
      best = state
    end
  end
  if best == nil then
    return nil
  end
  local match = result("word_prefix", best.spans, best.case_mismatches, best.skipped_words)
  match.skipped_bytes = best.skipped_bytes
  match.first_start = best.first_start
  return match
end

local function metrics(spans, case_mismatches, skipped_words)
  local skipped_bytes = 0
  local previous_end = 0
  for _, span in ipairs(spans) do
    skipped_bytes = skipped_bytes + span[1] - previous_end
    previous_end = span[2]
  end

  return {
    case_mismatches = case_mismatches or 0,
    skipped_bytes = skipped_bytes,
    skipped_words = skipped_words or 0,
    first_start = spans[1] and spans[1][1] or 0,
  }
end

result = function(level, spans, case_mismatches, skipped_words)
  local normalized_spans = utf8.coalesce_spans(spans)
  local match_metrics = metrics(normalized_spans, case_mismatches, skipped_words)
  return {
    level = level,
    spans = normalized_spans,
    case_mismatches = match_metrics.case_mismatches,
    skipped_bytes = match_metrics.skipped_bytes,
    skipped_words = match_metrics.skipped_words,
    first_start = match_metrics.first_start,
  }
end

better_state = function(left, right)
  if right == nil then
    return true
  end
  local keys = { "case_mismatches", "skipped_bytes", "skipped_words", "first_start" }
  for _, key in ipairs(keys) do
    if left[key] ~= right[key] then
      return left[key] < right[key]
    end
  end
  return left.path_key < right.path_key
end

local function finish_state(level, state)
  if state == nil then
    return nil
  end

  local reversed = {}
  local cursor = state
  while cursor ~= nil do
    reversed[#reversed + 1] = { cursor.start_byte, cursor.end_byte }
    cursor = cursor.previous
  end
  local spans = {}
  for index = #reversed, 1, -1 do
    spans[#spans + 1] = reversed[index]
  end

  local match = result(level, spans, state.case_mismatches, state.skipped_words)
  match.skipped_bytes = state.skipped_bytes
  match.first_start = state.first_start
  return match
end

local function word_prefix_match(query_words, candidate_words, sensitive, allow_skips, known_ascii)
  if #query_words == 0 or #candidate_words == 0 or #query_words > #candidate_words then
    return nil
  end

  local states = {}
  for query_index, query_word in ipairs(query_words) do
    local next_states = {}
    for candidate_index, candidate_word in ipairs(candidate_words) do
      local prefix = prefix_match(query_word.text, candidate_word.text, sensitive, known_ascii)
      if prefix ~= nil then
        if query_index == 1 and (allow_skips or candidate_index == 1) then
          next_states[candidate_index] = {
            case_mismatches = prefix.case_mismatches,
            skipped_bytes = candidate_word.start_byte,
            skipped_words = allow_skips and candidate_index - 1 or 0,
            first_start = candidate_word.start_byte,
            start_byte = candidate_word.start_byte,
            end_byte = candidate_word.start_byte + prefix.end_byte,
            path_key = string.format("%08d", candidate_index),
          }
        elseif query_index > 1 then
          local first_previous = allow_skips and 1 or candidate_index - 1
          for previous_index = first_previous, candidate_index - 1 do
            local previous = states[previous_index]
            if previous ~= nil then
              local candidate = {
                case_mismatches = previous.case_mismatches + prefix.case_mismatches,
                skipped_bytes = previous.skipped_bytes + candidate_word.start_byte - previous.end_byte,
                skipped_words = previous.skipped_words + candidate_index - previous_index - 1,
                first_start = previous.first_start,
                start_byte = candidate_word.start_byte,
                end_byte = candidate_word.start_byte + prefix.end_byte,
                path_key = previous.path_key .. ":" .. string.format("%08d", candidate_index),
                previous = previous,
              }
              if better_state(candidate, next_states[candidate_index]) then
                next_states[candidate_index] = candidate
              end
            end
          end
        end
      end
    end
    states = next_states
  end

  local best
  for index = 1, #candidate_words do
    local candidate = states[index]
    if candidate ~= nil and better_state(candidate, best) then
      best = candidate
    end
  end
  return finish_state("word_prefix", best)
end

local function initials_match(query, candidate_words, sensitive, prepared_characters, candidate_ascii)
  local query_characters = prepared_characters or utf8.chars(query)
  if query_characters == nil or #query_characters == 0 or #query_characters > #candidate_words then
    return nil
  end

  local initials = {}
  for index, word in ipairs(candidate_words) do
    if candidate_ascii or utf8.is_ascii(word.text) then
      initials[index] = {
        text = string.sub(word.text, 1, 1),
        start_byte = 0,
        end_byte = 1,
      }
    else
      local characters = utf8.chars(word.text)
      initials[index] = characters and characters[1] or nil
    end
  end

  local states = {}
  for query_index, query_character in ipairs(query_characters) do
    local next_states = {}
    for candidate_index, candidate_character in ipairs(initials) do
      if candidate_character ~= nil then
        local matches, mismatch = characters_match(query_character.text, candidate_character.text, sensitive)
        if matches then
          if query_index == 1 then
            next_states[candidate_index] = {
              case_mismatches = mismatch,
              skipped_bytes = candidate_words[candidate_index].start_byte,
              skipped_words = candidate_index - 1,
              first_start = candidate_words[candidate_index].start_byte,
              start_byte = candidate_words[candidate_index].start_byte,
              end_byte = candidate_words[candidate_index].start_byte + candidate_character.end_byte,
              path_key = string.format("%08d", candidate_index),
            }
          else
            for previous_index = 1, candidate_index - 1 do
              local previous = states[previous_index]
              if previous ~= nil then
                local candidate = {
                  case_mismatches = previous.case_mismatches + mismatch,
                  skipped_bytes = previous.skipped_bytes
                    + candidate_words[candidate_index].start_byte
                    - previous.end_byte,
                  skipped_words = previous.skipped_words + candidate_index - previous_index - 1,
                  first_start = previous.first_start,
                  start_byte = candidate_words[candidate_index].start_byte,
                  end_byte = candidate_words[candidate_index].start_byte + candidate_character.end_byte,
                  path_key = previous.path_key .. ":" .. string.format("%08d", candidate_index),
                  previous = previous,
                }
                if better_state(candidate, next_states[candidate_index]) then
                  next_states[candidate_index] = candidate
                end
              end
            end
          end
        end
      end
    end
    states = next_states
  end

  local best
  for index = 1, #candidate_words do
    local candidate = states[index]
    if candidate ~= nil and better_state(candidate, best) then
      best = candidate
    end
  end
  return finish_state("initials", best)
end

local function subsequence_match(query, candidate, sensitive, prepared_characters)
  local query_characters = prepared_characters or utf8.chars(query)
  local candidate_characters = utf8.chars(candidate)
  if query_characters == nil or candidate_characters == nil or #query_characters == 0 then
    return nil
  end

  local function better_predecessor(left, right)
    if right == nil then
      return true
    end
    if left.case_mismatches ~= right.case_mismatches then
      return left.case_mismatches < right.case_mismatches
    end
    local left_gap = left.skipped_bytes - left.end_byte
    local right_gap = right.skipped_bytes - right.end_byte
    if left_gap ~= right_gap then
      return left_gap < right_gap
    end
    if left.first_start ~= right.first_start then
      return left.first_start < right.first_start
    end
    return left.path_key < right.path_key
  end

  local states = {}
  for query_index, query_character in ipairs(query_characters) do
    local next_states = {}
    local predecessor
    for candidate_index, candidate_character in ipairs(candidate_characters) do
      if query_index > 1 then
        local eligible = states[candidate_index - 1]
        if eligible ~= nil and better_predecessor(eligible, predecessor) then
          predecessor = eligible
        end
      end
      local matches, mismatch = characters_match(query_character.text, candidate_character.text, sensitive)
      if matches and (query_index == 1 or predecessor ~= nil) then
        if query_index == 1 then
          next_states[candidate_index] = {
            case_mismatches = mismatch,
            skipped_bytes = candidate_character.start_byte,
            skipped_words = 0,
            first_start = candidate_character.start_byte,
            start_byte = candidate_character.start_byte,
            end_byte = candidate_character.end_byte,
            path_key = string.format("%08d", candidate_index),
          }
        else
          next_states[candidate_index] = {
            case_mismatches = predecessor.case_mismatches + mismatch,
            skipped_bytes = predecessor.skipped_bytes + candidate_character.start_byte - predecessor.end_byte,
            skipped_words = 0,
            first_start = predecessor.first_start,
            start_byte = candidate_character.start_byte,
            end_byte = candidate_character.end_byte,
            path_key = predecessor.path_key .. ":" .. string.format("%08d", candidate_index),
            previous = predecessor,
          }
        end
      end
    end
    states = next_states
  end

  local best
  for _, state in pairs(states) do
    if better_state(state, best) then
      best = state
    end
  end
  return finish_state("subsequence", best)
end

local function trim_trailing_empty(components)
  local count = #components
  if count > 1 and components[count].text == "" then
    count = count - 1
  end
  return count
end

shifted_spans = function(spans, offset)
  local shifted = {}
  for index, span in ipairs(spans) do
    shifted[index] = { span[1] + offset, span[2] + offset }
  end
  return shifted
end

append_spans = function(target, spans)
  for _, span in ipairs(spans) do
    target[#target + 1] = span
  end
end

local function path_match(query, candidate, sensitive, prepared_components, known_ascii, separator_mode)
  local query_components = prepared_components or boundaries.components(query, separator_mode)
  local candidate_components = boundaries.components(candidate, separator_mode)
  if query_components == nil or candidate_components == nil then
    return nil
  end

  local query_count = trim_trailing_empty(query_components)
  local candidate_count = trim_trailing_empty(candidate_components)
  local query_expands_children = #query_components > 1
    and query_components[#query_components].text == ""
    and candidate_count == query_count + 1
  if query_count ~= candidate_count and not query_expands_children then
    return nil
  end

  local whole_prefix = prefix_match(query, candidate, sensitive, known_ascii)
  if whole_prefix ~= nil and whole_prefix.query_characters == whole_prefix.candidate_characters then
    return result(
      "exact",
      whole_prefix.end_byte > 0 and { { 0, whole_prefix.end_byte } } or {},
      whole_prefix.case_mismatches,
      0
    )
  end
  if whole_prefix ~= nil and query_count == 1 and candidate_count == 1 then
    return result(
      "prefix",
      whole_prefix.end_byte > 0 and { { 0, whole_prefix.end_byte } } or {},
      whole_prefix.case_mismatches,
      0
    )
  end
  local spans = {}
  local case_mismatches = 0
  local skipped_words = 0
  local used_word_prefix = false
  for index = 1, query_count do
    local query_component = query_components[index]
    local candidate_component = candidate_components[index]
    if query_component.text == "" then
      if candidate_component.text ~= "" then
        return nil
      end
    else
      local prefix = prefix_match(query_component.text, candidate_component.text, sensitive, known_ascii)
      if prefix ~= nil then
        if prefix.end_byte > 0 then
          spans[#spans + 1] = {
            candidate_component.start_byte,
            candidate_component.start_byte + prefix.end_byte,
          }
        end
        case_mismatches = case_mismatches + prefix.case_mismatches
      else
        local query_words, explicit = boundaries.words(query_component.text, "path", known_ascii)
        local candidate_words = boundaries.words(candidate_component.text, "path", known_ascii)
        if not explicit and #query_words <= 1 then
          return nil
        end
        local word_match = word_prefix_match(query_words, candidate_words, sensitive, true, known_ascii)
        if word_match == nil then
          return nil
        end
        append_spans(spans, shifted_spans(word_match.spans, candidate_component.start_byte))
        case_mismatches = case_mismatches + word_match.case_mismatches
        skipped_words = skipped_words + word_match.skipped_words
        used_word_prefix = true
      end
    end
  end

  return result(used_word_prefix and "word_prefix" or "component_prefix", spans, case_mismatches, skipped_words)
end

local function emacs_path_match(query, candidate, sensitive, prepared_components, separator_mode)
  local query_components = prepared_components or boundaries.components(query, separator_mode)
  local candidate_components = boundaries.components(candidate, separator_mode)
  if query_components == nil or candidate_components == nil then
    return nil
  end

  local query_count = trim_trailing_empty(query_components)
  local candidate_count = trim_trailing_empty(candidate_components)
  local query_expands_children = #query_components > 1
    and query_components[#query_components].text == ""
    and candidate_count == query_count + 1
  if query_count ~= candidate_count and not query_expands_children then
    return nil
  end

  local whole_prefix = not string.find(query, "*", 1, true) and prefix_match(query, candidate, sensitive) or nil
  if whole_prefix ~= nil and whole_prefix.query_characters == whole_prefix.candidate_characters then
    return result(
      "exact",
      whole_prefix.end_byte > 0 and { { 0, whole_prefix.end_byte } } or {},
      whole_prefix.case_mismatches,
      0
    )
  end
  if whole_prefix ~= nil and query_count == 1 and candidate_count == 1 then
    return result(
      "prefix",
      whole_prefix.end_byte > 0 and { { 0, whole_prefix.end_byte } } or {},
      whole_prefix.case_mismatches,
      0
    )
  end

  local spans = {}
  local case_mismatches = 0
  local skipped_words = 0
  local used_words = false
  for index = 1, query_count do
    local query_component = query_components[index]
    local candidate_component = candidate_components[index]
    if query_component.text == "" then
      if index == 1 then
        if candidate_component.text ~= "" then
          return nil
        end
      elseif candidate_component.text == "" then
        return nil
      else
        skipped_words = skipped_words + 1
        used_words = true
      end
    else
      local component_match
      if query_component.text == "." or query_component.text == ".." then
        local prefix = prefix_match(query_component.text, candidate_component.text, sensitive)
        if prefix ~= nil then
          component_match = result(
            prefix.end_byte == #candidate_component.text and "exact" or "prefix",
            prefix.end_byte > 0 and { { 0, prefix.end_byte } } or {},
            prefix.case_mismatches,
            0
          )
        end
      else
        component_match = emacs_word_match(query_component.text, candidate_component.text, sensitive)
      end
      if component_match == nil then
        return nil
      end
      append_spans(spans, shifted_spans(component_match.spans, candidate_component.start_byte))
      case_mismatches = case_mismatches + component_match.case_mismatches
      skipped_words = skipped_words + component_match.skipped_words
      if component_match.level == "word_prefix" then
        used_words = true
      end
    end
  end

  return result(used_words and "word_prefix" or "component_prefix", spans, case_mismatches, skipped_words)
end

local function structured_match(query, candidate, profile, sensitive, prepared, candidate_ascii)
  local known_ascii = candidate_ascii and prepared and prepared.query_ascii
  if profile == "path" then
    return path_match(
      query,
      candidate,
      sensitive,
      prepared and prepared.path_components,
      known_ascii,
      prepared and prepared.path_separator
    )
  end

  local prefix = prefix_match(query, candidate, sensitive, known_ascii)
  if prefix ~= nil and prefix.query_characters == prefix.candidate_characters then
    return result("exact", prefix.end_byte > 0 and { { 0, prefix.end_byte } } or {}, prefix.case_mismatches, 0)
  end

  local query_words
  local explicit
  if prepared ~= nil and prepared.words[profile] ~= nil then
    query_words = prepared.words[profile].words
    explicit = prepared.words[profile].explicit
  else
    query_words, explicit = boundaries.words(query, profile, prepared and prepared.query_ascii)
  end
  local candidate_words = boundaries.words(candidate, profile, candidate_ascii)
  if query_words == nil or candidate_words == nil then
    return nil
  end

  if profile == "generic" and explicit then
    local words = word_prefix_match(query_words, candidate_words, sensitive, false, known_ascii)
    if words ~= nil then
      return words
    end
  end

  if prefix ~= nil then
    return result("prefix", prefix.end_byte > 0 and { { 0, prefix.end_byte } } or {}, prefix.case_mismatches, 0)
  end

  if explicit or #query_words > 1 then
    local words = word_prefix_match(query_words, candidate_words, sensitive, profile ~= "generic", known_ascii)
    if words ~= nil then
      return words
    end
  end

  if profile == "symbol" and not explicit then
    return initials_match(query, candidate_words, sensitive, prepared and prepared.query_characters, candidate_ascii)
  end
  return nil
end

local function emacs_structured_match(query, candidate, profile, sensitive, prepared)
  if profile == "path" then
    return emacs_path_match(
      query,
      candidate,
      sensitive,
      prepared and prepared.path_components,
      prepared and prepared.path_separator
    )
  end
  return emacs_word_match(query, candidate, sensitive)
end

local function score(match)
  local base = level_rank[match.level]
  local function fraction(value)
    return value / (value + 1)
  end
  return base
    - 0.4 * fraction(match.case_mismatches)
    - 0.2 * fraction(match.skipped_bytes)
    - 0.1 * fraction(match.skipped_words)
    - 0.05 * fraction(match.first_start)
end

local function match_prepared(query, candidate, profile, prepared, candidate_ascii)
  local category = profile.category or "generic"
  local profile_name = profile.profile or boundaries.profile_for(category, query, candidate, profile.path_separator)
  local case_mode = profile.case_mode or boundaries.default_case_mode(category)
  local sensitive = prepared and prepared.sensitive
  if sensitive == nil then
    sensitive = effective_sensitive(query, case_mode)
  end
  local match
  if profile.matching_style == "emacs" then
    match = emacs_structured_match(query, candidate, profile_name, sensitive, prepared)
  else
    match = structured_match(query, candidate, profile_name, sensitive, prepared, candidate_ascii)
  end
  if match == nil and profile.allow_subsequence == true then
    match = subsequence_match(query, candidate, sensitive, prepared and prepared.query_characters)
  end
  if match == nil then
    return nil
  end

  if path_children_query(query, profile_name, profile.path_separator) then
    match.score = -character_count(candidate, candidate_ascii)
  else
    match.score = score(match)
  end
  return match
end

function M.match(query, candidate, profile)
  if type(query) ~= "string" or type(candidate) ~= "string" or type(profile) ~= "table" then
    return nil
  end
  local query_ascii = utf8.is_ascii(query)
  local candidate_ascii = utf8.is_ascii(candidate)
  if (not query_ascii and not utf8.is_valid(query)) or (not candidate_ascii and not utf8.is_valid(candidate)) then
    return nil
  end
  return match_prepared(query, candidate, profile, {
    query_ascii = query_ascii,
    path_separator = profile.path_separator,
    words = {},
  }, candidate_ascii)
end

local function compare_ranked(left, right)
  local left_match = left.match
  local right_match = right.match
  if level_rank[left_match.level] ~= level_rank[right_match.level] then
    return level_rank[left_match.level] > level_rank[right_match.level]
  end

  local ascending = { "case_mismatches", "skipped_bytes", "skipped_words", "first_start" }
  for _, key in ipairs(ascending) do
    if left_match[key] ~= right_match[key] then
      return left_match[key] < right_match[key]
    end
  end

  if #left._match_text ~= #right._match_text then
    return #left._match_text < #right._match_text
  end
  if left._folded_text ~= right._folded_text then
    return left._folded_text < right._folded_text
  end
  if left._match_text ~= right._match_text then
    return left._match_text < right._match_text
  end
  if left._source_order ~= right._source_order then
    return left._source_order < right._source_order
  end
  return left._stable_id < right._stable_id
end

local function compare_path_children(left, right)
  if left._character_count ~= right._character_count then
    return left._character_count < right._character_count
  end
  if left._match_text ~= right._match_text then
    return left._match_text < right._match_text
  end
  if left._source_order ~= right._source_order then
    return left._source_order < right._source_order
  end
  return left._stable_id < right._stable_id
end

local function compare_emacs(left, right)
  if left._character_count ~= right._character_count then
    return left._character_count < right._character_count
  end
  if left._match_text ~= right._match_text then
    return left._match_text < right._match_text
  end
  if left._source_order ~= right._source_order then
    return left._source_order < right._source_order
  end
  return left._stable_id < right._stable_id
end

function M.rank(query, candidates, profile)
  if type(query) ~= "string" or type(profile) ~= "table" or not utf8.is_valid(query) then
    return {}
  end
  local category = profile.category or "generic"
  local resolved_profile = profile.profile or boundaries.profile_for(category, query, query, profile.path_separator)
  local sort_path_children = path_children_query(query, resolved_profile, profile.path_separator)
  local sort_emacs = profile.matching_style == "emacs"
  local case_mode = profile.case_mode or boundaries.default_case_mode(category)
  local prepared = {
    sensitive = effective_sensitive(query, case_mode),
    query_ascii = utf8.is_ascii(query),
    query_characters = utf8.chars(query),
    path_components = boundaries.components(query, profile.path_separator),
    path_separator = profile.path_separator,
    words = {},
  }
  for _, profile_name in ipairs({ "symbol", "generic", "path" }) do
    local words, explicit = boundaries.words(query, profile_name, prepared.query_ascii)
    prepared.words[profile_name] = { words = words, explicit = explicit }
  end

  local ranked = {}
  for _, candidate in ipairs(candidates) do
    local item
    local text
    if type(candidate) == "string" then
      item = { label = candidate, insert_text = candidate }
      text = candidate
    elseif type(candidate) == "table" then
      item = {}
      for key, value in pairs(candidate) do
        item[key] = value
      end
      text = candidate.text or candidate.label
    end

    if type(text) == "string" then
      local candidate_ascii = utf8.is_ascii(text)
      local valid = candidate_ascii or utf8.is_valid(text)
      local candidate_prepared = prepared
      if item._case_mode == "sensitive" or item._case_mode == "insensitive" then
        candidate_prepared = {
          sensitive = effective_sensitive(query, item._case_mode),
          query_ascii = prepared.query_ascii,
          query_characters = prepared.query_characters,
          path_components = prepared.path_components,
          path_separator = prepared.path_separator,
          words = prepared.words,
        }
      end
      local match = valid and match_prepared(query, text, profile, candidate_prepared, candidate_ascii) or nil
      if match ~= nil then
        item.match = match
        item._match_text = text
        item._folded_text = candidate_ascii and string.lower(text) or utf8.lower(text) or text
        item._character_count = (sort_path_children or sort_emacs) and character_count(text, candidate_ascii) or 0
        item._source_order = type(item.source_order) == "number" and item.source_order or 0
        item._stable_id = tostring(item.id or text)
        ranked[#ranked + 1] = item
      end
    end
  end

  table.sort(ranked, sort_emacs and compare_emacs or (sort_path_children and compare_path_children or compare_ranked))
  for index, item in ipairs(ranked) do
    item.match.score = #ranked - index + 1
    item._match_text = nil
    item._folded_text = nil
    item._character_count = nil
    item._source_order = nil
    item._stable_id = nil
  end
  return ranked
end

return M
