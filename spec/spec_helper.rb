require "cli/ui"
require_relative "support/real_llm_root_guard"

# cli-ui enables colour whenever STDOUT is a TTY, and it reads the real STDOUT
# rather than the StringIO `output(...).to_stdout` captures -- so every output
# assertion passes piped and fails when the suite is run in a terminal.
CLI::UI.enable_color = false

# Footprint budgets against the driver's free-VRAM reading, so a spec that
# stubs only gpu_total_mib would price itself against the real card and drift
# with whatever the desktop happens to hold. Default it unreadable; the specs
# that care about it stub it themselves.
require_relative "../lib/mimic/util/host"

RSpec.configure do |config|
  config.before { allow(Mimic::Util::Host).to receive(:gpu_free_mib).and_return(nil) }
end
