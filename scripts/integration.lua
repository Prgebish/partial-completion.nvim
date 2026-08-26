require("tests.helpers.runner").run({
  label = "Neovim integration tests",
  output_prefix = "integration: ",
  patterns = { "tests/integration/*_spec.lua" },
  required_files = {
    "tests/integration/cmdline_spec.lua",
    "tests/integration/filesystem_spec.lua",
    "tests/integration/hardening_spec.lua",
    "tests/integration/native_spec.lua",
  },
  minimum_files = 4,
  minimum_tests = 37,
  allowed_load_namespaces = { "partial-completion.native" },
})
