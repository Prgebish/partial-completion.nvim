local config = require("partial_completion.config")

local M = {}

function M.should_observe(current_generation, cancelled, event_generation)
  return not cancelled and current_generation == event_generation
end

local function same_replacement(left, right)
  return left == nil and right == nil
    or (
      type(left) == "table"
      and type(right) == "table"
      and left.start_byte == right.start_byte
      and left.end_byte == right.end_byte
    )
end

function M.same_context(snapshot, live)
  if type(snapshot) ~= "table" or type(live) ~= "table" then
    return false
  end
  return same_replacement(snapshot.replacement, live.replacement)
    and snapshot.generation == live.generation
    and snapshot.source_text == live.source_text
    and snapshot.cursor_byte == live.cursor_byte
    and snapshot.cmdtype == live.cmdtype
    and snapshot.cmdlevel == live.cmdlevel
    and snapshot.completion_type == live.completion_type
end

function M.contract_decision(case)
  if case.request_snapshot ~= nil then
    return M.same_context(case.request_snapshot, case.live_context) and "accept" or "stale_context"
  end
  if case.event ~= nil then
    return M.should_observe(case.current_generation, case.cancelled == true, case.event.generation) and "observe"
      or "discard"
  end
  return "discard"
end

local Session = {}
Session.__index = Session

local function item_key(item)
  if type(item) ~= "table" or type(item.id) ~= "string" then
    return nil
  end
  return tostring(item.source or "") .. "\0" .. item.id
end

local function replacement_from(request, update)
  if type(update) == "table" and update.replacement ~= nil then
    return config.copy(update.replacement)
  end
  return type(request) == "table" and config.copy(request.replacement) or nil
end

function Session:_report_error(err)
  if self.on_error ~= nil then
    pcall(self.on_error, tostring(err))
  end
end

function Session:_notify(event, update, snapshot)
  if self.on_change == nil then
    return
  end
  local ok, err = pcall(self.on_change, config.copy(snapshot or self:snapshot()), event, config.copy(update))
  if not ok then
    self:_report_error(err)
  end
end

function Session:_take_handle()
  local handle = self.handle
  self.handle = nil
  return handle
end

function Session:_transition(status, reason, result)
  if self.status ~= "active" then
    return false
  end
  self.status = status
  self.reason = reason
  self.result = config.copy(result)
  local handle = self:_take_handle()
  local snapshot = self:snapshot()
  if handle ~= nil and type(handle.cancel) == "function" then
    pcall(handle.cancel, handle)
  end
  self:_notify(status, nil, snapshot)
  if self.on_close ~= nil then
    local ok, err = pcall(self.on_close, snapshot, reason)
    if not ok then
      self:_report_error(err)
    end
  end
  return true
end

function Session:snapshot()
  return {
    generation = self.generation,
    request_id = self.request_id,
    provider_generation = self.provider_generation,
    request = config.copy(self.request),
    replacement = replacement_from(self.request, self.update),
    items = config.copy(self.items),
    selected_id = self.selected_id,
    selected_source = self.selected_source,
    status = self.status,
    done = self.done,
    is_incomplete = self.is_incomplete,
    error = config.copy(self.error),
    reason = self.reason,
    result = config.copy(self.result),
  }
end

function Session:_selected_index()
  if self.selected_id == nil then
    return nil
  end
  local key = tostring(self.selected_source or "") .. "\0" .. self.selected_id
  for index, item in ipairs(self.items) do
    if item_key(item) == key then
      return index
    end
  end
  return nil
end

function Session:selected_item()
  local index = self:_selected_index()
  return index and config.copy(self.items[index]) or nil
end

function Session:_replace_items(items)
  local previous_index = self:_selected_index() or 1
  local selected_key = item_key(self:selected_item())
  local normalized = {}
  for _, item in ipairs(items) do
    if item_key(item) ~= nil then
      normalized[#normalized + 1] = config.copy(item)
    end
  end
  self.items = normalized

  local selected
  if selected_key ~= nil then
    for index, item in ipairs(self.items) do
      if item_key(item) == selected_key then
        selected = index
        break
      end
    end
  end
  if selected == nil and self.select_first and #self.items > 0 then
    selected = math.min(previous_index, #self.items)
  end
  local item = selected and self.items[selected] or nil
  self.selected_id = item and item.id or nil
  self.selected_source = item and item.source or nil
end

function Session:_observe(generation, update)
  if self.status ~= "active" or self.generation ~= generation or type(update) ~= "table" then
    return false
  end
  if update.request_id ~= nil then
    if self.request_id ~= nil and self.request_id ~= update.request_id then
      return false
    end
    self.request_id = update.request_id
  end
  if update.generation ~= nil then
    if self.provider_generation ~= nil and self.provider_generation ~= update.generation then
      return false
    end
    self.provider_generation = update.generation
  end
  if update.replacement ~= nil and not same_replacement(self.request.replacement, update.replacement) then
    return false
  end

  local observed = config.copy(update)
  self.update = observed
  self.done = observed.done == true
  self.is_incomplete = observed.is_incomplete == true
  self.error = config.copy(observed.error)
  self:_replace_items(type(observed.items) == "table" and observed.items or {})
  self:_notify("update", observed)
  return true
end

function Session:start(request)
  if type(request) ~= "table" then
    error("session request must be a table", 2)
  end
  self.start_epoch = self.start_epoch + 1
  local start_epoch = self.start_epoch
  if self.status == "active" then
    self:_transition("cancelled", "replaced")
    if self.start_epoch ~= start_epoch then
      return self
    end
  end

  self.generation = self.generation + 1
  local generation = self.generation
  self.request = config.copy(request)
  self.request_id = nil
  self.provider_generation = nil
  self.items = {}
  self.selected_id = nil
  self.selected_source = nil
  self.status = "active"
  self.done = false
  self.is_incomplete = false
  self.error = nil
  self.reason = nil
  self.result = nil
  self.update = nil
  self.handle = nil
  self:_notify("start", nil)
  if self.start_epoch ~= start_epoch or self.status ~= "active" or self.generation ~= generation then
    return self
  end

  local ok, handle = pcall(self.complete, config.copy(self.request), function(update)
    self:_observe(generation, update)
  end)
  if not ok then
    self:_report_error(handle)
    self:_transition("cancelled", "completion_error")
    return self
  end
  if handle ~= nil and (type(handle) ~= "table" or type(handle.cancel) ~= "function") then
    self:_report_error("completion returned an invalid cancel handle")
    self:_transition("cancelled", "invalid_handle")
    return self
  end
  if self.status == "active" and self.generation == generation then
    self.handle = handle
  elseif handle ~= nil then
    pcall(handle.cancel, handle)
  end
  return self
end

function Session:select(index_or_id, source)
  if self.status ~= "active" or #self.items == 0 then
    return nil, "no_items"
  end
  local index
  if type(index_or_id) == "number" and index_or_id % 1 == 0 then
    index = index_or_id
  elseif type(index_or_id) == "string" then
    for candidate_index, item in ipairs(self.items) do
      if item.id == index_or_id and (source == nil or item.source == source) then
        index = candidate_index
        break
      end
    end
  end
  if index == nil or index < 1 or index > #self.items then
    return nil, "invalid_selection"
  end
  local item = self.items[index]
  self.selected_id = item.id
  self.selected_source = item.source
  self:_notify("selection", nil)
  return config.copy(item)
end

function Session:select_next(delta)
  if self.status ~= "active" or #self.items == 0 then
    return nil, "no_items"
  end
  delta = delta or 1
  if type(delta) ~= "number" or delta % 1 ~= 0 or delta == 0 then
    return nil, "invalid_selection_delta"
  end
  local index = self:_selected_index() or (delta > 0 and 0 or 1)
  index = ((index - 1 + delta) % #self.items) + 1
  return self:select(index)
end

function Session:accept(acceptor, item)
  if self.status ~= "active" then
    return nil, "session_not_active"
  end
  local canonical
  if item ~= nil then
    local key = item_key(item)
    if key == nil then
      return nil, "invalid_item"
    end
    local current
    for _, candidate in ipairs(self.items) do
      if item_key(candidate) == key then
        current = candidate
        break
      end
    end
    if current == nil then
      return nil, "invalid_item"
    end
    canonical = current
  else
    local index = self:_selected_index()
    canonical = index and self.items[index] or nil
  end
  if type(canonical) ~= "table" then
    return nil, "no_selection"
  end
  if type(acceptor) ~= "function" then
    return nil, "invalid_acceptor"
  end
  local start_epoch = self.start_epoch
  local generation = self.generation
  local ok, result, err = pcall(acceptor, config.copy(canonical), self:snapshot())
  if not ok then
    self:_report_error(result)
    return nil, "accept_error"
  end
  if result == nil then
    return nil, err or "accept_rejected"
  end
  if self.start_epoch ~= start_epoch or self.generation ~= generation or self.status ~= "active" then
    return nil, "accept_superseded"
  end
  self:_transition("accepted", "accepted", result)
  return result
end

function Session:cancel(reason)
  self:_transition("cancelled", reason or "cancelled")
  return self
end

function Session:close(reason)
  self:_transition("closed", reason or "closed")
  return self
end

function M.new(options)
  if type(options) ~= "table" or type(options.complete) ~= "function" then
    error("session requires a complete callback", 2)
  end
  return setmetatable({
    complete = options.complete,
    on_change = options.on_change,
    on_close = options.on_close,
    on_error = options.on_error,
    select_first = options.select_first ~= false,
    generation = 0,
    start_epoch = 0,
    request = {},
    items = {},
    status = "closed",
    done = false,
    is_incomplete = false,
  }, Session)
end

return M
