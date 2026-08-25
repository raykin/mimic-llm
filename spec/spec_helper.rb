require "cli/ui"
require_relative "support/real_llm_root_guard"

# cli-ui enables colour whenever STDOUT is a TTY, and it reads the real STDOUT
# rather than the StringIO `output(...).to_stdout` captures -- so every output
# assertion passes piped and fails when the suite is run in a terminal.
CLI::UI.enable_color = false
