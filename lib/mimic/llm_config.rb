require "date"
require "psych"
require "json"
require "pathname"
require_relative "paths"

# LLM engine config -- model + llama keys, separate from mimic service
# config. Owned by the `llm` CLI; the main `mimic` config reads from it for
# base URL, model alias, and context length (needed on every agent launch).
module Mimic
  module LlmConfig
    LLM_CONFIG_DIR = Paths::LLM_ROOT
    LLM_CONFIG_PATH = LLM_CONFIG_DIR / "config.yaml"
    MODEL_CTX_PATH = LLM_CONFIG_DIR / "model-ctx.json"
    LEGACY_CONFIG = Paths::STATE_DIR / "llm_config.yaml"

    BUILTIN_MODEL_DIRS = [
      Pathname.new(Dir.home) / "hf-models",
      LLM_CONFIG_DIR / "models",
      Pathname.new(Dir.home) / ".lmstudio/models",
    ].freeze

    DEFAULTS = {
      "model" => {
        "path" => "",
        "search_paths" => [],
        "context_length" => 122_880,
        "mtp" => "auto",
        "temperature" => 0.6,
        "top_p" => 0.95,
        "top_k" => 20,
        "min_p" => 0.0,
        "presence_penalty" => 1.5,
        "repeat_penalty" => 1.0,
      },
      "llama" => {
        "engine" => "llama.cpp",
        "host" => "127.0.0.1",
        "port" => 8080,
        "flash_attn" => "on",
        "cache_type" => "q8_0",
        "n_slots" => 1,
        "binary" => "",
      },
    }.freeze

    class << self
      def merge(base, override)
        out = Marshal.load(Marshal.dump(base))
        override.each do |key, value|
          out[key] = value.is_a?(Hash) && out[key].is_a?(Hash) ? merge(out[key], value) : value
        end
        out
      end

      def load
        migrate_legacy
        return Settings.new(merge(DEFAULTS, {})) unless LLM_CONFIG_PATH.exist?

        data = Psych.safe_load(LLM_CONFIG_PATH.read, permitted_classes: [Symbol, Date, Time], aliases: true) || {}
        Settings.new(merge(DEFAULTS, data))
      end

      def exists?
        migrate_legacy
        LLM_CONFIG_PATH.exist?
      end

      def recall_ctx(model_path) = CtxStore.recall(model_path)

      # ~/hf-models is a tree of per-file symlinks into their .lmstudio
      # targets, and this store has to be keyed by the resolved target so a
      # model reached through a different symlink still matches. expand_path
      # alone leaves the symlink unresolved and splits the store into two
      # disagreeing key sets; realdirpath covers the non-strict case for a
      # path whose file is gone.
      def resolve_path(path)
        expanded = Pathname.new(path).expand_path
        return expanded.realpath.to_s if expanded.exist?

        expanded.realdirpath.to_s
      rescue SystemCallError
        expanded.to_s
      end

      private

      # Relocate the engine config left behind when it lived under STATE_DIR.
      def migrate_legacy
        return if LLM_CONFIG_PATH.exist? || !LEGACY_CONFIG.file?

        LLM_CONFIG_DIR.mkpath
        LEGACY_CONFIG.rename(LLM_CONFIG_PATH)
      end
    end

    # The context each model last booted at, keyed by resolved GGUF path.
    #
    # config.yaml holds one active profile, so switching models overwrites
    # the context it was tuned for and the next pick starts from whatever
    # the last model used -- which is how an oversized preset gets carried
    # onto a model that cannot hold it. This file is per-model and
    # additive, like ik-n-cpu-moe.json.
    module CtxStore
      class << self
        def recall(model_path)
          entry = read[LlmConfig.resolve_path(model_path)]
          return nil unless entry

          [entry["context_length"], entry["cache_type"]]
        end

        def remember(model_path, context_length, cache_type)
          known = read
          known[LlmConfig.resolve_path(model_path)] = {
            "context_length" => context_length,
            "cache_type" => cache_type,
          }
          LLM_CONFIG_DIR.mkpath
          MODEL_CTX_PATH.write(JSON.pretty_generate(known))
        end

        private

        def read
          JSON.parse(MODEL_CTX_PATH.read)
        rescue SystemCallError, JSON::ParserError
          {}
        end
      end
    end

    class Settings
      QUANT_MARKERS = %w[-Q4 -Q5 -Q6 -Q8 -IQ -F16 -BF16].freeze

      def self.alias_for(path)
        stem = Pathname.new(path).basename(".*").to_s
        marker = QUANT_MARKERS.find { |m| stem.include?(m) }
        marker ? stem.split(marker).first : stem
      end

      def initialize(cfg)
        @cfg = cfg
      end

      def model_path = @cfg["model"]["path"]
      def context_length = @cfg["model"]["context_length"]
      def cache_type = @cfg["llama"]["cache_type"]
      def engine = @cfg["llama"].fetch("engine", "llama.cpp")
      def port = @cfg["llama"]["port"]
      def host = @cfg["llama"]["host"]
      def n_slots = @cfg["llama"].fetch("n_slots", 1)
      def flash_attn = @cfg["llama"]["flash_attn"]
      def mtp = @cfg["model"].fetch("mtp", "auto")
      def binary = @cfg["llama"]["binary"]

      def save
        LLM_CONFIG_DIR.mkpath
        LLM_CONFIG_PATH.write(Psych.dump(@cfg.slice("model", "llama")))
      end

      def remember_ctx
        CtxStore.remember(model_path, context_length, cache_type)
      end

      def search_paths
        (BUILTIN_MODEL_DIRS + configured_search_paths.map { |dir| Pathname.new(dir.to_s).expand_path }).uniq
      end

      def add_search_path(dir)
        wanted = Pathname.new(dir.to_s).expand_path
        return :builtin if BUILTIN_MODEL_DIRS.include?(wanted)
        return :duplicate if configured_search_paths.map { |p| Pathname.new(p).expand_path }.include?(wanted)

        store_search_paths(configured_search_paths + [wanted.to_s])
        :added
      end

      def remove_search_path(dir)
        wanted = Pathname.new(dir.to_s).expand_path
        stored = configured_search_paths
        kept = stored.reject { |p| Pathname.new(p).expand_path == wanted }
        return BUILTIN_MODEL_DIRS.include?(wanted) ? :builtin : :missing if kept.size == stored.size

        store_search_paths(kept)
        :removed
      end

      def model_path=(value)
        @cfg["model"]["path"] = value
      end

      def context_length=(value)
        @cfg["model"]["context_length"] = value
      end

      def cache_type=(value)
        @cfg["llama"]["cache_type"] = value
      end

      def engine=(value)
        @cfg["llama"]["engine"] = value
      end

      def binary=(value)
        @cfg["llama"]["binary"] = value
      end

      def n_slots=(value)
        @cfg["llama"]["n_slots"] = value
      end

      def temperature = @cfg["model"]["temperature"]
      def top_p = @cfg["model"]["top_p"]
      def top_k = @cfg["model"]["top_k"]
      def min_p = @cfg["model"]["min_p"]
      def presence_penalty = @cfg["model"]["presence_penalty"]
      def repeat_penalty = @cfg["model"]["repeat_penalty"]

      def ik? = engine == "ik_llama.cpp"

      # Loopback URL for clients, not the server's bind address.
      #
      # `llama.host` is 0.0.0.0 so containers can reach the server; writing
      # that into a client-facing URL would be wrong -- every client on this
      # host (mimic claude/codex, hermes, status checks) dials 127.0.0.1.
      def base_url = "http://127.0.0.1:#{port}"

      def model_alias = self.class.alias_for(model_path)

      def to_h = @cfg

      private

      def configured_search_paths = @cfg.dig("model", "search_paths") || []

      def store_search_paths(paths)
        (@cfg["model"] ||= {})["search_paths"] = paths
      end
    end
  end
end
