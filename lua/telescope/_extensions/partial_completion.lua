local adapter = require("partial_completion.adapters.telescope")

return require("telescope").register_extension({
  setup = function(extension_config)
    adapter.setup(extension_config)
  end,
  exports = {
    files = adapter.files,
    commands = adapter.commands,
  },
})
