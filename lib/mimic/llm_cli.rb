require "thor"
require "pastel"
require "tty-prompt"
require "tty-box"
require_relative "benchmark_wizard"
require_relative "engine_update"
require_relative "llm_config"
require_relative "llm_paths_cli"
require_relative "models_table"
require_relative "moe_wizard"
require_relative "probes"
require_relative "result"
require_relative "server_status"
require_relative "setup_wizard"
require_relative "services/clients"
require_relative "services/engines"
require_relative "services/llama"
require_relative "services/engine"

# LLM CLI -- owns llama.cpp / ik_llama.cpp management.
#
# Carved out of `mimic setup` / `start` / `restart`. Takes:
#   start/stop/restart/status/update + wizard steps 1-5 (system check, engine,
#   binary, model, context preset).
module Mimic
  class LlmCli < Thor
    def self.exit_on_failure? = true

    def initialize(*args)
      super
      @pastel = Pastel.new
      @prompt = TTY::Prompt.new
    end

    desc "setup", "interactive LLM setup wizard"
    def setup
      wizard_run
    end

    desc "start", "start llama-server"
    def start
      report(Services::Engine.for(require_config).start)
    end

    desc "stop", "stop llama-server"
    def stop
      puts "llama-server: #{Services::Llama.stop ? 'stopped' : 'was not running'}"
    end

    desc "restart", "stop then start llama-server"
    def restart
      stop
      return unless wait_for_release(LlmConfig.load, "restart")

      start
    end

    desc "status", "llama-server status"
    def status
      ServerStatus.new(LlmConfig.load, pastel: @pastel).print
    end

    desc "path SUBCOMMAND", "manage the directories scanned for models"
    subcommand "path", LlmPathsCli

    desc "moe", "interactive wizard to view/set/clear a MoE model's cached --n-cpu-moe value"
    def moe
      MoeWizard.new(wizard.scan_gguf, prompt: @prompt, pastel: @pastel).run
    end

    desc "models", "list available GGUF models"
    def models
      cfg = LlmConfig.load
      ModelsTable.new(cfg, wizard.scan_gguf, pastel: @pastel).render
    end

    desc "update", "check engine updates + rebuild"
    method_option :rollback, type: :string, enum: Services::Engines::ENGINES.keys, desc: "print the command to rebuild an engine at its last-good commit"
    def update
      require_config
      updater = EngineUpdate.new(pastel: @pastel)
      if options[:rollback]
        failure = updater.rollback(options[:rollback])
        report(failure) if failure
        return
      end

      updater.run
    end

    # `diffusion` (DiffusionGemma, unmerged llama.cpp PR #24423) is
    # deliberately not exposed as a Thor command -- it's an experiment, not
    # a working product (truncates mid-answer; --diffusion-blocks doesn't
    # extend past block 1, root cause not yet found). Services::Diffusion
    # stays wired for whoever picks this back up.

    desc "config", "edit LLM config values"
    def config
      require_relative "llm_configure"
      LlmConfigure.run
    end

    desc "sync", "push the active LLM config to #{Services::Clients::CLIENTS.join(', ')}"
    def sync(cfg = nil)
      cfg ||= LlmConfig.load
      synced = Services::Clients.sync(cfg)
      synced.each { |name| puts "#{@pastel.green('synced')} #{name}" }
      puts @pastel.yellow("no SWE agent configs found") if synced.empty?
      synced
    end

    desc "benchmark", "restart with n_slots/ctx overrides for throughput testing (not persisted)"
    method_option :slots, type: :numeric, desc: "n_slots override"
    method_option :ctx, type: :numeric, desc: "context_length override"
    def benchmark
      cfg = benchmark_config(require_config)

      stop
      return unless wait_for_release(cfg, "benchmark start")

      report(Services::Engine.for(cfg).start(remember: false))
    end

    private

    def require_config
      unless LlmConfig.exists?
        puts @pastel.yellow("No LLM config yet -- running setup wizard first.")
        return wizard_run
      end
      LlmConfig.load
    end

    def report(result)
      puts result.ok? ? @pastel.green(result.message) : @pastel.red(result.message)
      raise SystemExit, 1 unless result.ok?
    end

    def wizard
      @wizard ||= SetupWizard.new(LlmConfig.load, prompt: @prompt, pastel: @pastel)
    end

    def benchmark_config(cfg)
      return BenchmarkWizard.new(cfg, wizard, prompt: @prompt, pastel: @pastel).run unless options[:slots] || options[:ctx]

      cfg.n_slots = options[:slots].to_i if options[:slots]
      cfg.context_length = options[:ctx].to_i if options[:ctx]
      cfg
    end

    def wizard_run
      cfg = wizard.config
      puts TTY::Box.frame("llm -- setup wizard", padding: 0)

      wizard.system_check
      wizard.ensure_binary(wizard.choose_engine)
      wizard.choose_model
      wizard.choose_context

      cfg.save
      Services::Engine.for(cfg).render_preset
      print_setup_summary(sync(cfg))

      if @prompt.yes?("Start llama-server now?") { |q| q.default true }
        restart
      else
        puts "Next: `llm restart` to launch llama-server."
      end
      cfg
    end

    def print_setup_summary(synced)
      puts TTY::Box.frame(
        "LLM config saved to #{LlmConfig::LLM_CONFIG_PATH}\n" \
        "Preset written to #{Services::Llama::PRESET_FILE}\n" \
        "Agents synced: #{synced.empty? ? 'none found' : synced.join(', ')}",
        padding: 0
      )
    end

    def wait_for_release(cfg, action)
      released = Probes.wait_until(attempts: 30, delay: 1, label: "waiting for port to be released") { released?(cfg) }
      return true if released

      report(Result.error("llama-server still holds #{cfg.host}:#{cfg.port} -- #{action} aborted"))
      false
    end

    def released?(cfg)
      Probes.find_pid_by_cmd("llama-server").nil? && Probes.port_free?(cfg.host, cfg.port.to_i)
    end
  end
end
