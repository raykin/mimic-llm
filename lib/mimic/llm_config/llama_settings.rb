module Mimic
  module LlmConfig
    # The engine section: which llama-server build runs, where it binds, and
    # the knobs that belong to the server rather than to the model.
    class LlamaSettings
      SECTION = "llama".freeze

      def initialize(cfg)
        @cfg = cfg
      end

      def engine = section.fetch("engine", "llama.cpp")
      def host = section["host"]
      def port = section["port"]
      def n_slots = section.fetch("n_slots", 1)
      def flash_attn = section["flash_attn"]
      def cache_type = section["cache_type"]
      def ik? = engine == "ik_llama.cpp"

      # `binary` is per-engine: llama.cpp and ik_llama.cpp are different
      # binaries, so one flat field meant switching engines could hand the
      # wrong engine the other's path. A pre-split config.yaml is upgraded to
      # the per-engine hash by LlmConfig.load, so a String here only reaches
      # a section built by hand.
      def binary
        raw = section["binary"]
        raw.is_a?(Hash) ? raw[engine].to_s : raw.to_s
      end

      # Loopback URL for clients, not the server's bind address.
      #
      # `llama.host` is 0.0.0.0 so containers can reach the server; writing
      # that into a client-facing URL would be wrong -- every client on this
      # host (mimic claude/codex, hermes, status checks) dials 127.0.0.1.
      def base_url = "http://127.0.0.1:#{port}"

      def engine=(value)
        writable["engine"] = value
      end

      def cache_type=(value)
        writable["cache_type"] = value
      end

      def n_slots=(value)
        writable["n_slots"] = value
      end

      def binary=(value)
        raw = section["binary"]
        writable["binary"] = raw.is_a?(Hash) ? raw.merge(engine => value) : { engine => value }
      end

      private

      def section = @cfg[SECTION] || {}
      def writable = @cfg[SECTION] ||= {}
    end
  end
end
