require "date"
require "psych"
require "pathname"
require_relative "../config"
require_relative "../llm_config"
require_relative "../probes"

module Mimic
  module Services
    module Hermes
      HERMES_CONFIG_PATH = Pathname.new(Dir.home) / ".hermes/config.yaml"

      AUXILIARY_TIMEOUTS = {
        "background_review" => 300,
        "vision" => 120,
        "web_extract" => 120,
        "compression" => 180,
        "skills_hub" => 90,
        "approval" => 60,
        "mcp" => 120,
        "flush_memories" => 45,
        "title_generation" => 15,
      }.freeze

      DEAD_MODEL_KEYS = %w[path temperature top_p top_k min_p presence_penalty repeat_penalty].freeze

      class << self
        def find_binary
          venv_binary = Config::HERMES_VENV / "bin/hermes"
          return venv_binary.to_s if venv_binary.file?

          Probes.which("hermes")
        end

        # Merge mimic-derived keys into hermes' own config, preserving the rest.
        def sync_config(settings)
          existing = HERMES_CONFIG_PATH.file? ? (Psych.safe_load(HERMES_CONFIG_PATH.read, permitted_classes: [Symbol, Date, Time], aliases: true) || {}) : {}
          merged = LlmConfig.merge(existing, managed_keys(settings))
          DEAD_MODEL_KEYS.each { |key| merged.fetch("model", {}).delete(key) }
          HERMES_CONFIG_PATH.dirname.mkpath
          HERMES_CONFIG_PATH.write(Psych.dump(merged))
          HERMES_CONFIG_PATH
        end

        # Launch Hermes with the Claude Code bridge env.
        #
        # Plain `hermes` is not wrapped here: it needs nothing mimic can add,
        # since the config lives at hermes' own path and DDGS_PROXY is
        # exported by the shell. Only the bridge justifies a launcher.
        def launch(settings, extra_args)
          binary = find_binary
          abort "hermes binary not found -- run `mimic setup`" if binary.nil?

          require_relative "../agent"
          Process.exec(Mimic::Agent::Claude.new(settings).env, binary, *extra_args)
        end

        private

        def managed_keys(settings)
          model_alias = settings.model_alias
          base_url = "#{settings.base_url}/v1"
          provider = "custom:local-llama-cpp"
          {
            "providers" => {
              "local-llama-cpp" => {
                "name" => "llama.cpp",
                "base_url" => base_url,
                "api_key" => "llama.cpp",
                "api_mode" => "chat_completions",
                "default_model" => model_alias,
                "model" => model_alias,
                "models" => [model_alias],
              },
            },
            "model" => {
              "default" => model_alias,
              "provider" => provider,
              "base_url" => base_url,
              "context_length" => settings.context_length,
            },
            # Only summary_model: the rest of hermes' compression block
            # (threshold, enabled, protect_last_n) is hermes' own, edited with
            # `hermes config set`.
            "compression" => { "summary_model" => model_alias },
            "auxiliary" => AUXILIARY_TIMEOUTS.to_h do |task, timeout|
              [task, { "provider" => provider, "model" => model_alias, "timeout" => timeout }]
            end,
          }
        end
      end
    end
  end
end
