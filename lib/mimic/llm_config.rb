require "date"
require "psych"
require "json"
require "pathname"
require_relative "paths"
require_relative "model"
require_relative "llm_config/sampling"
require_relative "llm_config/settings"

# LLM engine config -- model + llama keys, separate from mimic service
# config. Owned by the `llm` CLI; the main `mimic` config reads from it for
# base URL, model alias, and context length (needed on every agent launch).
module Mimic
  module LlmConfig
    LLM_CONFIG_DIR = Paths::LLM_ROOT
    LLM_CONFIG_PATH = LLM_CONFIG_DIR / "config.yaml"
    MODEL_CTX_PATH = LLM_CONFIG_DIR / "model-ctx.json"
    MODEL_MMPROJ_PATH = LLM_CONFIG_DIR / "model-mmproj.json"
    MODEL_COMPUTE_PATH = LLM_CONFIG_DIR / "model-compute.json"
    MODEL_SAMPLING_PATH = LLM_CONFIG_DIR / "model-sampling.json"
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
        "reasoning" => "auto",
      },
      "llama" => {
        "engine" => "llama.cpp",
        "host" => "127.0.0.1",
        "port" => 8080,
        "flash_attn" => "on",
        "cache_type" => "q8_0",
        "n_slots" => 1,
        "binary" => {},
      },
      "embed" => {
        "path" => "",
        "port" => 8081,
        "context_length" => 0,
        "batch_size" => 8192,
        "mode" => "auto",
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
        migrate_stores(Settings.new(merge(DEFAULTS, data)))
      end

      def exists?
        migrate_legacy
        LLM_CONFIG_PATH.exist?
      end

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

      # Relocate the fields that used to sit flat in config.yaml:
      # model.mmproj_path (now per model, in Model::Memory) and a plain
      # llama.binary string (now per engine). Both are relocated with the
      # attribution they had when they were written -- the projector to the
      # model that is configured, the binary to the engine that is configured
      # -- and the old keys are dropped so nothing reads them again. The
      # sampler keys are dropped outright: they resolve from the chosen
      # model's own header now, so a stale hand-edited value would only
      # contradict it. model.thinking was a boolean translated to the engines'
      # reasoning value at read time; the value itself is stored now, so the
      # translation happens once here instead.
      def migrate_stores(settings)
        cfg = settings.to_h
        legacy_binary = cfg["llama"]["binary"] if cfg["llama"]["binary"].is_a?(String)
        legacy_sampling = Sampling::KEYS.any? { |key| cfg["model"].key?(key) }
        legacy_thinking = cfg["model"].key?("thinking")
        return settings unless cfg["model"].key?("mmproj_path") || legacy_binary ||
                               legacy_sampling || legacy_thinking

        projector = cfg["model"].delete("mmproj_path").to_s
        settings.model.mmproj_path = projector unless projector.empty?
        settings.llama.binary = legacy_binary if legacy_binary
        settings.model.reasoning = cfg["model"].delete("thinking") ? "auto" : "off" if legacy_thinking
        Sampling::KEYS.each { |key| cfg["model"].delete(key) }
        settings.save
        settings
      end
    end
  end
end
