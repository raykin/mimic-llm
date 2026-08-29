require_relative "ui"
require_relative "llm_config"
require_relative "engine"
require_relative "health"
require_relative "agent/hermes"
require_relative "paths"

module Mimic
  # mimic/claude/codex/hermes-lcc all take a REMAINDER of pass-through
  # args after the subcommand name, which Thor's own flag parser would
  # otherwise try (and fail) to interpret -- dispatch manually instead.
  class Cli
    Command = Struct.new(:name, :help, :menu, :handler, :dev)

    COMMANDS = [
      Command.new("verify", "check installs, running services and recent errors",
                  "Verify stack (installs, services, errors)", :verify),
      Command.new("install-hermes", "install hermes-agent into ~/.hermes/venv",
                  "Install hermes-agent into an isolated venv", :install_hermes),
      Command.new("hermes-lcc", "Hermes -> claude-code skill -> Claude Code -> llama.cpp",
                  "Launch Hermes + Claude Code bridge (claude-code skill direct to llama.cpp)", :hermes_lcc),
      Command.new("claude", "Claude Code -> llama.cpp via Unsloth's start recipe",
                  "Launch Claude Code -- direct to llama.cpp (Unsloth start recipe)", :claude),
      Command.new("codex", "Codex -> llama.cpp via Unsloth's config recipe",
                  "Launch Codex -- direct to llama.cpp (Unsloth config recipe)", :codex),
      # `dev` holds muse back from an installed gem. It is wired correctly,
      # but llama-server's /v1/responses stream omits `model` from
      # response.created and muse aborts on the first event -- upstream
      # llama.cpp PR #21174 is the fix, unmerged. Nothing an installed gem
      # can do about it, so it is not offered there.
      Command.new("muse", "Muse Code -> llama.cpp via its Responses base URL",
                  "Launch Muse Code -- direct to llama.cpp (Responses API)", :muse, true),
    ].freeze

    # The menu leads with the launchers -- what someone opening it without a
    # command almost always wants -- so it does not follow the help order.
    MENU_ORDER = %w[hermes-lcc claude codex muse verify install-hermes].freeze

    HELP_FLAGS = %w[-h --help].freeze

    def initialize(argv)
      @argv = argv
    end

    def run
      require_linux!
      return menu unless command
      return print_help if HELP_FLAGS.include?(command)

      entry = commands.find { |c| c.name == command }
      return unknown_command unless entry

      send(entry.handler, extra)
    end

    def menu
      picked = Ui::Prompt.new.select("mimic-llm:", menu_entries.map(&:menu))
      send(menu_entries.find { |c| c.menu == picked }.handler, [])
    rescue Interrupt
      nil
    end

    private

    def command = @argv.first
    def extra = @argv[1..] || []

    # Every command this build offers: a dev-only one is absent in an
    # installed gem and present in a checkout.
    def commands = COMMANDS.reject { |c| c.dev && !Paths.dev_build? }
    def menu_entries = MENU_ORDER.filter_map { |name| commands.find { |c| c.name == name } }

    def hermes_lcc(extra)
      cfg = require_config
      require_llama_running!(cfg, "`mimic hermes-lcc`")
      Agent::Hermes.launch(cfg, extra)
    end

    def claude(extra)
      cfg = require_config
      require_llama_running!(cfg, "`mimic claude`")
      require_relative "agent"
      Agent::Claude.new(cfg).launch(extra)
    end

    def codex(extra)
      cfg = require_config
      require_llama_running!(cfg, "`mimic codex`")
      require_relative "agent"
      Agent::Codex.new(cfg).launch(extra)
    end

    def muse(extra)
      cfg = require_config
      require_llama_running!(cfg, "`mimic muse`")
      require_relative "agent"
      Agent::Muse.new(cfg).launch(extra)
    end

    # Single stack check: installs, running services, recent errors.
    def verify(_extra)
      raise SystemExit, 1 unless Health.run(require_config)
    end

    def install_hermes(_extra)
      binary = Agent::Hermes.find_binary
      return puts "#{Ui.green('hermes found:')} #{binary}" if binary

      unless Ui::Prompt.new.yes?("hermes-agent not found. Install into an isolated venv?", default: true)
        return puts Ui.yellow("Skipping Hermes -- `mimic hermes-lcc` will not work.")
      end

      puts "#{Ui.green('hermes installed:')} #{Agent::Hermes.install}"
    end

    def unknown_command
      warn "unknown command: #{command}"
      print_help
      raise SystemExit, 1
    end

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
        #{command_lines}

        (no command)    interactive menu
      HELP
    end

    def command_lines
      width = commands.map { |c| c.name.length }.max + 1
      commands.map { |c| "  #{c.name.ljust(width)}#{c.help}" }.join("\n")
    end
  end
end
