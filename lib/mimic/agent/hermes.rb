require "date"
require "psych"
require "pathname"
require_relative "../llm_config"
require_relative "../util/probes"
require_relative "claude"

module Mimic
  module Agent
    module Hermes
      DIR = Pathname.new(Dir.home) / ".hermes"
      VENV = DIR / "venv"
      CONFIG_PATH = DIR / "config.yaml"
      AGENT_LOG = DIR / "logs" / "agent.log"
      ERRORS_LOG = DIR / "logs" / "errors.log"
      STATE_DB = DIR / "state.db"

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

      DEAD_MODEL_KEYS = ["path", *LlmConfig::Sampling::KEYS].freeze

      class << self
        def find_binary
          venv_binary = VENV / "bin/hermes"
          return venv_binary.to_s if venv_binary.file?

          Util::Probes.which("hermes")
        end

        def install
          unless (VENV / "bin/pip").file?
            VENV.dirname.mkpath
            system("python", "-m", "venv", VENV.to_s, exception: true)
          end
          system((VENV / "bin/pip").to_s, "install", "--upgrade", "hermes-agent", exception: true)
          (VENV / "bin/hermes").to_s
        end

        # Merge mimic-derived keys into hermes' own config, preserving the rest.
        def sync_config(settings)
          existing = CONFIG_PATH.file? ? (Psych.safe_load(CONFIG_PATH.read, permitted_classes: [Symbol, Date, Time], aliases: true) || {}) : {}
          merged = LlmConfig.merge(existing, managed_keys(settings))
          DEAD_MODEL_KEYS.each { |key| merged.fetch("model", {}).delete(key) }
          CONFIG_PATH.dirname.mkpath
          CONFIG_PATH.write(Psych.dump(merged))
          CONFIG_PATH
        end

        # Launch Hermes with the Claude Code bridge env.
        #
        # Plain `hermes` is not wrapped here: it needs nothing mimic can add,
        # since the config lives at hermes' own path and DDGS_PROXY is
        # exported by the shell. Only the bridge justifies a launcher.
        def launch(settings, extra_args)
          binary = find_binary
          abort "hermes binary not found -- run `mimic setup`" if binary.nil?

          Process.exec(Claude.new(settings).env, binary, *extra_args)
        end

        private

        def managed_keys(settings)
          model_alias = settings.model.name
          base_url = "#{settings.llama.base_url}/v1"
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
              "context_length" => settings.model.context_length,
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
