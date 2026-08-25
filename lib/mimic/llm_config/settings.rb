require "psych"
require "pathname"
require_relative "../llm_config"
require_relative "model_settings"
require_relative "llama_settings"
require_relative "embed"

module Mimic
  module LlmConfig
    # The directories scanned for GGUF files: the builtin roots plus whatever
    # `llm path add` has stored. Enumerating it yields every directory in
    # scan order; add/remove report what they did as a symbol so the CLI can
    # tell "already there" apart from "not yours to remove".
    class SearchPaths
      include Enumerable

      def initialize(cfg)
        @cfg = cfg
      end

      def each(&) = all.each(&)

      def all
        (BUILTIN_MODEL_DIRS + configured.map { |dir| Pathname.new(dir.to_s).expand_path }).uniq
      end

      def add(dir)
        wanted = Pathname.new(dir.to_s).expand_path
        return :builtin if BUILTIN_MODEL_DIRS.include?(wanted)
        return :duplicate if configured.map { |p| Pathname.new(p).expand_path }.include?(wanted)

        store(configured + [wanted.to_s])
        :added
      end

      def remove(dir)
        wanted = Pathname.new(dir.to_s).expand_path
        kept = configured.reject { |p| Pathname.new(p).expand_path == wanted }
        return BUILTIN_MODEL_DIRS.include?(wanted) ? :builtin : :missing if kept.size == configured.size

        store(kept)
        :removed
      end

      private

      def configured = @cfg.dig("model", "search_paths") || []

      def store(paths)
        (@cfg["model"] ||= {})["search_paths"] = paths
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

      def model = @model ||= ModelSettings.new(@cfg)
      def llama = @llama ||= LlamaSettings.new(@cfg)

      def save
        LLM_CONFIG_DIR.mkpath
        model.save
        LLM_CONFIG_PATH.write(Psych.dump(@cfg.slice("model", "llama", "embed")))
      end

      def remember_ctx
        model.file.memory.remember_ctx(model.context_length, llama.cache_type)
      end

      def remember_sampling
        model.file.memory.remember_sampling(model.reasoning, model.file.memory.sampling_for(reasoning: model.reasoning))
      end

      def forget_sampling = model.file.memory.forget_sampling

      def search_paths = SearchPaths.new(@cfg)
      def embed = @embed ||= Embed.new(@cfg["embed"] ||= {}, host: llama.host)

      def to_h = @cfg
    end
  end
end
