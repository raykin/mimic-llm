require "pathname"
require_relative "llm_config"

# Paths mimic drives, plus a passthrough to the one config file it reads.
#
# mimic is a pipeline, not a config owner. Hermes keeps its own config under
# ~/.hermes; Claude Code keeps its own under the unsloth agent home; the
# engine keeps its own under ~/.llm. Anything mimic once stored on top of
# those was a default with a settable name, so the paths below are
# constants instead.
module Mimic
  module Config
    HERMES_DIR = Pathname.new(Dir.home) / ".hermes"
    HERMES_VENV = HERMES_DIR / "venv"
    AGENT_LOG = HERMES_DIR / "logs" / "agent.log"
    ERRORS_LOG = HERMES_DIR / "logs" / "errors.log"
    STATE_DB = HERMES_DIR / "state.db"

    class << self
      def load
        LlmConfig.load
      end

      def exists?
        LlmConfig.exists?
      end
    end
  end
end
