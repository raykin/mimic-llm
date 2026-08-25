require_relative "base"
require_relative "models_table"
require_relative "../model/library"
require_relative "../llm_config"
require_relative "../util/hf"

module Mimic
  module LlmCli
    # `llm models` -- the board of every GGUF under the search paths.
    class Models < Base
      default_command :list

      desc "list", "list available GGUF models"
      def list
        board.render
      end

      desc "check", "compare each local GGUF against the repo it was published from"
      def check
        board(client: Util::Hf.new).render
      end

      private

      def board(client: nil)
        cfg = LlmConfig.load
        ModelsTable.new(cfg, Model::Library.new(cfg).chat_loadable_or_hidden, client: client)
      end
    end
  end
end
