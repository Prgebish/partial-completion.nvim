if vim.g.loaded_partial_completion == 1 then
  return
end

if vim.fn.has("nvim-0.12") ~= 1 then
  vim.notify("partial-completion requires Neovim 0.12 or newer", vim.log.levels.ERROR)
  return
end

vim.g.loaded_partial_completion = 1
local completion = require("partial_completion")

vim.api.nvim_create_user_command("PartialCompletionEnable", function()
  completion.enable_native()
end, { desc = "Enable the partial-completion native command-line UI" })

vim.api.nvim_create_user_command("PartialCompletionDisable", function()
  completion.disable_native()
end, { desc = "Disable the partial-completion native command-line UI" })

vim.api.nvim_create_user_command("PartialCompletionToggle", function()
  if completion.native_enabled() then
    completion.disable_native()
  else
    completion.enable_native()
  end
end, { desc = "Toggle the partial-completion native command-line UI" })
