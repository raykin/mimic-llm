require_relative "ui"
require_relative "llm_config"
require_relative "engine"
require_relative "health"
require_relative "agent/hermes"

module Mimic
  module Cli
    # mimic/claude/codex/hermes-lcc all take a REMAINDER of pass-through
    # args after the subcommand name, which Thor's own flag parser would
    # otherwise try (and fail) to interpret -- dispatch manually instead.
    COMMANDS = %w[verify install-hermes hermes-lcc claude codex].freeze

    class << self
      def menu
        prompt = Ui::Prompt.new
        picked = prompt.select("mimic-llm:", MENU.map(&:first))
        handler = MENU.to_h.fetch(picked)
        handler.call([])
      rescue Interrupt
        nil
      end

      def run(argv)
        require_linux!
        command = argv.first
        return menu unless command

        extra = argv[1..] || []
        case command
        when "verify" then cmd_verify(extra)
        when "install-hermes" then cmd_install_hermes(extra)
        when "hermes-lcc" then cmd_hermes_lcc(extra)
        when "claude" then cmd_claude(extra)
        when "codex" then cmd_codex(extra)
        when "-h", "--help" then print_help
        else
          warn "unknown command: #{command}"
          print_help
          raise SystemExit, 1
        end
      end

      def cmd_hermes_lcc(extra)
        cfg = require_config
        require_llama_running!(cfg, "`mimic hermes-lcc`")
        Agent::Hermes.launch(cfg, extra)
      end

      def cmd_claude(extra)
        cfg = require_config
        require_llama_running!(cfg, "`mimic claude`")
        require_relative "agent"
        Agent::Claude.new(cfg).launch(extra)
      end

      def cmd_codex(extra)
        cfg = require_config
        require_llama_running!(cfg, "`mimic codex`")
        require_relative "agent"
        Agent::Codex.new(cfg).launch(extra)
      end

      # Single stack check: installs, running services, recent errors.
      def cmd_verify(_extra)
        raise SystemExit, 1 unless Health.run(require_config)
      end

      def cmd_install_hermes(_extra)
        binary = Agent::Hermes.find_binary
        return puts "#{Ui.green('hermes found:')} #{binary}" if binary

        unless Ui::Prompt.new.yes?("hermes-agent not found. Install into an isolated venv?", default: true)
          return puts Ui.yellow("Skipping Hermes -- `mimic hermes-lcc` will not work.")
        end

        puts "#{Ui.green('hermes installed:')} #{Agent::Hermes.install}"
      end

      private

      def require_linux!
        abort "mimic-llm supports Linux only" unless RUBY_PLATFORM.include?("linux")
      end

      def require_config
        abort "no LLM config yet -- run `llm setup` first" unless LlmConfig.exists?

        LlmConfig.load
      end

      # Check that llama-server is running; fail with a clear message if not.
      def require_llama_running!(cfg, context)
        return if Engine::Llama.new(cfg).running?

        puts "#{Ui.red("#{context} requires llama-server to be running.")}\n" \
             "  Run `#{Ui.cyan('llm start')}` first."
        raise SystemExit, 1
      end

      def print_help
        puts <<~HELP
          usage: mimic [command] [args...]

          Local Hermes + Claude Code stack

          commands:
            verify         check installs, running services and recent errors
            install-hermes install hermes-agent into ~/.hermes/venv
            hermes-lcc     Hermes -> claude-code skill -> Claude Code -> llama.cpp
            claude         Claude Code -> llama.cpp via Unsloth's start recipe
            codex          Codex -> llama.cpp via Unsloth's config recipe

          (no command)    interactive menu
        HELP
      end
    end

    MENU = [
      ["Launch Hermes + Claude Code bridge (claude-code skill direct to llama.cpp)", method(:cmd_hermes_lcc)],
      ["Launch Claude Code -- direct to llama.cpp (Unsloth start recipe)", method(:cmd_claude)],
      ["Launch Codex -- direct to llama.cpp (Unsloth config recipe)", method(:cmd_codex)],
      ["Verify stack (installs, services, errors)", method(:cmd_verify)],
      ["Install hermes-agent into an isolated venv", method(:cmd_install_hermes)],
    ].freeze
  end
end
