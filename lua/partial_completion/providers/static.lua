local M = {
  api_version = 1,
  categories = { "generic" },
}

function M.new(items, categories)
  local provider = {
    api_version = 1,
    categories = categories or { "generic" },
  }

  function provider.complete(_, emit, done)
    emit(items, { is_incomplete = false })
    done(nil)
    return {
      cancel = function() end,
    }
  end

  return provider
end

return M
