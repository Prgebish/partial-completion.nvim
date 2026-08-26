local M = {}
M.__index = M

local function supports(provider, category)
  for _, supported in ipairs(provider.categories) do
    if supported == category or supported == "*" then
      return true
    end
  end
  return false
end

function M.new()
  return setmetatable({ by_name = {}, metadata = {}, order = {} }, M)
end

function M:register(name, provider, options)
  options = options or {}
  if type(name) ~= "string" or name == "" then
    error("provider name must be a non-empty string", 2)
  end
  if options.already_filtered ~= nil and type(options.already_filtered) ~= "boolean" then
    error("provider already_filtered must be boolean", 2)
  end
  if
    type(provider) ~= "table"
    or provider.api_version ~= 1
    or type(provider.categories) ~= "table"
    or type(provider.complete) ~= "function"
  then
    error("provider must implement API version 1", 2)
  end
  if self.by_name[name] ~= nil and options.replace ~= true then
    error("provider already registered: " .. name, 2)
  end
  if self.by_name[name] == nil then
    self.order[#self.order + 1] = name
  end
  self.by_name[name] = provider
  self.metadata[name] = {
    already_filtered = options.already_filtered == true,
  }
end

function M:resolve(request)
  if request.provider ~= nil then
    local provider = self.by_name[request.provider]
    if provider == nil then
      return nil, "unknown provider: " .. request.provider
    end
    if not supports(provider, request.category) then
      return nil, "provider does not support category: " .. request.category
    end
    return request.provider, provider
  end

  for _, name in ipairs(self.order) do
    local provider = self.by_name[name]
    if supports(provider, request.category) then
      return name, provider
    end
  end
  return nil, "no provider for category: " .. request.category
end

return M
