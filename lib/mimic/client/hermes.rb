require_relative "base"
require_relative "../agent/hermes"

module Mimic
  module Client
    # Hermes is a client of llama-server like any other: its managed keys are
    # all LLM-derived (alias, base URL, context length), so it belongs on this
    # roster rather than in the agent-side setup. The config itself lives at
    # hermes' own path, which Agent::Hermes owns.
    class Hermes < Base
      def config_path = Agent::Hermes::CONFIG_PATH

      def sync
        return false unless config_path.dirname.directory?

        Agent::Hermes.sync_config(@settings)
        true
      end
    end
  end
end
