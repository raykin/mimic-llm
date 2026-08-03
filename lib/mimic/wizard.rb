require "tty-prompt"
require "tty-box"
require "pastel"
require_relative "config"
require_relative "llm_config"
require_relative "setup_wizard"
require_relative "probes"
require_relative "services/clients"
require_relative "services/hermes"
require_relative "services/llama"
require_relative "services/engine"

module Mimic
  module Wizard
    TOTAL_STEPS = 7

    class << self
      def run(cfg)
        prompt = TTY::Prompt.new
        wizard = SetupWizard.new(cfg, total: TOTAL_STEPS, cli_name: "mimic", prompt: prompt, pastel: pastel)
        puts TTY::Box.frame("mimic-llm -- setup wizard", padding: 0)

        wizard.system_check
        engine = wizard.choose_engine
        wizard.ensure_binary(engine)
        wizard.choose_model
        wizard.choose_context

        wizard.step("Hermes Agent")
        ensure_hermes(prompt)

        wizard.step("Claude Code")
        check_claude

        persist(cfg)
        cfg
      rescue TTY::Reader::InputInterrupt
        puts "\n#{pastel.yellow('Setup cancelled.')}"
        raise SystemExit, 1
      end

      def ensure_hermes(prompt)
        binary = Services::Hermes.find_binary
        if binary
          puts "#{pastel.green('hermes found:')} #{binary}"
          return binary
        end
        unless prompt.yes?("hermes-agent not found. Install into an isolated venv?") { |q| q.default true }
          puts pastel.yellow("Skipping Hermes -- `mimic hermes` will not work.")
          return nil
        end

        install_hermes
      end

      private

      def pastel
        @pastel ||= Pastel.new
      end

      def install_hermes
        venv_dir = Config::HERMES_VENV
        unless (venv_dir / "bin/pip").file?
          venv_dir.dirname.mkpath
          system("python", "-m", "venv", venv_dir.to_s, exception: true)
        end
        system((venv_dir / "bin/pip").to_s, "install", "--upgrade", "hermes-agent", exception: true)
        (venv_dir / "bin/hermes").to_s
      end

      def check_claude
        require_relative "agent"
        if Agent::Claude.find_binary
          puts pastel.green("claude found on PATH")
        else
          puts pastel.yellow("claude not found -- install Claude Code before `mimic hermes-lcc`")
        end
        Agent::Claude.ensure_config_dir
      end

      def persist(cfg)
        cfg.save
        Services::Hermes.sync_config(cfg)
        Services::Engine.for(cfg).render_preset
        synced_clients = Services::Clients.sync(cfg)
        puts TTY::Box.frame(
          "Config saved to #{LlmConfig::LLM_CONFIG_PATH}\n" \
          "Synced: ~/.hermes/config.yaml, #{Services::Llama::PRESET_FILE}\n" \
          "Client configs: #{synced_clients.empty? ? 'none found' : synced_clients.join(', ')}\n" \
          "Next: `mimic hermes` (direct) or `mimic hermes-lcc` (Claude Code bridge)",
          padding: 0
        )
      end
    end
  end
end
