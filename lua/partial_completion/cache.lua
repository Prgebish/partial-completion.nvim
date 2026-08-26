local M = {}
M.__index = M

local function default_clock()
  return vim.uv.hrtime() / 1000000
end

local function positive_integer(value, fallback)
  if type(value) == "number" and value >= 1 and value % 1 == 0 then
    return value
  end
  return fallback
end

local function finite_number(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

function M.new(options)
  options = options or {}
  return setmetatable({
    clock = options.clock or default_clock,
    max_entries = positive_integer(options.max_entries, 128),
    max_bytes = positive_integer(options.max_bytes, 4 * 1024 * 1024),
    ttl_ms = finite_number(options.ttl_ms) and math.max(0, options.ttl_ms) or 1000,
    entries = {},
    entry_count = 0,
    byte_count = 0,
    tick = 0,
    counters = {
      hits = 0,
      misses = 0,
      evictions = 0,
      expirations = 0,
      invalidations = 0,
    },
  }, M)
end

function M:_remove(key, counter)
  local entry = self.entries[key]
  if entry == nil then
    return false
  end
  self.entries[key] = nil
  self.entry_count = self.entry_count - 1
  self.byte_count = self.byte_count - entry.size
  if counter ~= nil then
    self.counters[counter] = self.counters[counter] + 1
  end
  return true
end

function M:_evict()
  while self.entry_count > self.max_entries or self.byte_count > self.max_bytes do
    local oldest_key
    local oldest_tick
    for key, entry in pairs(self.entries) do
      if oldest_tick == nil or entry.tick < oldest_tick then
        oldest_key = key
        oldest_tick = entry.tick
      end
    end
    if oldest_key == nil then
      break
    end
    self:_remove(oldest_key, "evictions")
  end
end

function M:get(key)
  local entry = self.entries[key]
  if entry == nil or self.ttl_ms == 0 then
    self.counters.misses = self.counters.misses + 1
    return nil
  end
  if self.clock() - entry.created_at >= self.ttl_ms then
    self:_remove(key, "expirations")
    self.counters.misses = self.counters.misses + 1
    return nil
  end
  self.tick = self.tick + 1
  entry.tick = self.tick
  self.counters.hits = self.counters.hits + 1
  return entry.value
end

function M:set(key, value, size)
  if self.ttl_ms == 0 then
    return
  end
  size = math.max(1, math.floor(tonumber(size) or 1))
  self:_remove(key)
  self.tick = self.tick + 1
  self.entries[key] = {
    value = value,
    size = size,
    created_at = self.clock(),
    tick = self.tick,
  }
  self.entry_count = self.entry_count + 1
  self.byte_count = self.byte_count + size
  self:_evict()
end

function M:invalidate(key)
  if key ~= nil then
    if self:_remove(key) then
      self.counters.invalidations = self.counters.invalidations + 1
    end
    return
  end
  local removed = self.entry_count
  self.entries = {}
  self.entry_count = 0
  self.byte_count = 0
  self.counters.invalidations = self.counters.invalidations + removed
end

function M:stats()
  return {
    hits = self.counters.hits,
    misses = self.counters.misses,
    evictions = self.counters.evictions,
    expirations = self.counters.expirations,
    invalidations = self.counters.invalidations,
    entries = self.entry_count,
    bytes = self.byte_count,
  }
end

return M
