require_relative "quality/engine_seed"
require_relative "quality/harness"
require_relative "quality/sweep"
require_relative "quality/command"

module Mimic
  module LlmCli
    module Dev
      # `llm quality` -- score every model in the library, not just whichever
      # one is configured.
      #
      # Command is the Thor surface, Sweep drives the engine between models,
      # Harness is the external script that does the scoring, and EngineSeed
      # reads its results log back into a per-model engine verdict.
      module Quality
      end
    end
  end
end
