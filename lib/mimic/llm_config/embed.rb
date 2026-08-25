require_relative "../llm_config"

module Mimic
  module LlmConfig
    # The embedding server's profile: its own model and its own port, so it
    # can serve /v1/embeddings beside the chat server rather than in place of
    # it. `mode` picks the endpoint llama-server exposes -- "auto" reads the
    # GGUF's pooling type, "embeddings" and "rerank" force it.
    class Embed
      MODES = %w[auto embeddings rerank].freeze

      def initialize(cfg, host:)
        @cfg = cfg
        @host = host
      end

      def path = @cfg["path"].to_s
      def port = @cfg.fetch("port", 8081)
      def context_length = @cfg.fetch("context_length", 0)
      def batch_size = @cfg.fetch("batch_size", 8192)
      def mode = @cfg.fetch("mode", "auto")
      def host = @host
      def configured? = !path.empty?
      def model_alias = Settings.alias_for(path)
      def base_url = "http://127.0.0.1:#{port}"

      def path=(value)
        @cfg["path"] = value
      end

      def port=(value)
        @cfg["port"] = value
      end

      def context_length=(value)
        @cfg["context_length"] = value
      end

      def batch_size=(value)
        @cfg["batch_size"] = value
      end

      def mode=(value)
        @cfg["mode"] = value
      end
    end
  end
end
