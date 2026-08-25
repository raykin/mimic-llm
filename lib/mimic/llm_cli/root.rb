require_relative "../ui"
require_relative "base"
require_relative "embed"
require_relative "paths"
require_relative "update"
require_relative "wizard/parallel"
require_relative "../engine_cli"
require_relative "../llm_config"
require_relative "models"
require_relative "wizard/moe"
require_relative "../model/library"
require_relative "../util/probes"
require_relative "../result"
require_relative "../engine_cli/status"
require_relative "wizard/setup"
require_relative "../client"
require_relative "../engine/llama_embed"

# LLM CLI -- owns llama.cpp / ik_llama.cpp management.
#
# Carved out of `mimic setup` / `start` / `restart`. Takes:
#   start/stop/restart/status/update + wizard steps 1-5 (system check, engine,
#   binary, model, context preset).
module Mimic
  module LlmCli
    if Mimic::Paths.dev_build?
      require_relative "dev/debug"
      require_relative "dev/quality"
    end

    class Root < Base
      desc "setup", "interactive LLM setup wizard"
      def setup
        wizard_run
      end

      desc "start", "start llama-server"
      def start
        report(EngineCli::Registry.for(require_config).start)
      end

      desc "stop", "stop llama-server"
      def stop
        stopped = Engine::ServerProcess.chat.stop(exclude: Engine::ServerProcess.embed.pids)
        puts "llama-server: #{stopped ? 'stopped' : 'was not running'}"
      end

      desc "restart", "stop then start llama-server"
      def restart
        stop
        return unless wait_for_release(LlmConfig.load, "restart")

        start
      end

      desc "status", "llama-server status"
      def status
        EngineCli::Status.new(LlmConfig.load).print
      end

      desc "embed SUBCOMMAND", "run an embedding model beside llama-server"
      subcommand "embed", Embed

      desc "path SUBCOMMAND", "manage the directories scanned for models"
      subcommand "path", Paths

      desc "moe", "interactive wizard to view/set/clear a MoE model's cached --n-cpu-moe value"
      def moe
        Wizard::Moe.new(Model::Library.new(LlmConfig.load).all, prompt: @prompt).run
      end

      desc "models SUBCOMMAND", "list available GGUF models"
      subcommand "models", Models

      # `debug` and `quality` are development tools, not product: one restarts
      # the engines back to back to shake out launch bugs, the other sweeps the
      # whole model shelf through a benchmark harness that lives in the stack
      # repo and is not shipped. The gemspec leaves lib/mimic/llm_cli/dev out
      # of the package, so this directory is absent in an installed gem and the
      # commands register only in a checkout.
      if Mimic::Paths.dev_build?
        desc "debug SUBCOMMAND", "run local engine integration checks"
        subcommand "debug", Dev::Debug

        desc "quality SUBCOMMAND", "score every model in the library against the local quality harness"
        subcommand "quality", Dev::Quality::Command
      end

      desc "update SUBCOMMAND", "check for updates and rebuild"
      subcommand "update", Update

      # `diffusion` (DiffusionGemma, unmerged llama.cpp PR #24423) is
      # deliberately not exposed as a Thor command -- it's an experiment, not
      # a working product (truncates mid-answer; --diffusion-blocks doesn't
      # extend past block 1, root cause not yet found). EngineCli::Diffusion
      # stays wired for whoever picks this back up.

      desc "config", "edit LLM config values"
      def config
        require_relative "configure"
        LlmCli::Configure.run
      end

      desc "sync", "push the active LLM config to #{Client::CLIENTS.join(', ')}"
      def sync(cfg = nil)
        cfg ||= LlmConfig.load
        synced = Client.sync(cfg)
        synced.each { |name| puts "#{Ui.green('synced')} #{name}" }
        puts Ui.yellow("no SWE agent configs found") if synced.empty?
        synced
      end

      desc "parallel", "restart with n_slots/ctx overrides so several tasks can run at once (not persisted)"
      method_option :slots, type: :numeric, desc: "n_slots override"
      method_option :ctx, type: :numeric, desc: "context_length override"
      def parallel
        cfg = parallel_config(require_config)

        stop
        return unless wait_for_release(cfg, "parallel start")

        report(EngineCli::Registry.for(cfg).start(remember: false))
      end

      private

      def require_config
        unless LlmConfig.exists?
          puts Ui.yellow("No LLM config yet -- running setup wizard first.")
          return wizard_run
        end
        LlmConfig.load
      end

      def wizard
        @wizard ||= Wizard::Setup.new(LlmConfig.load, prompt: @prompt)
      end

      def parallel_config(cfg)
        return Wizard::Parallel.new(cfg, wizard, prompt: @prompt).run unless options[:slots] || options[:ctx]

        cfg.llama.n_slots = options[:slots].to_i if options[:slots]
        cfg.model.context_length = options[:ctx].to_i if options[:ctx]
        cfg
      end

      def wizard_run
        cfg = wizard.config
        Ui.banner("llm -- setup wizard")

        wizard.system_check
        wizard.ensure_binary(wizard.choose_engine)
        wizard.choose_model
        wizard.choose_mmproj
        wizard.choose_context
        wizard.choose_reasoning

        cfg.save
        cfg.forget_sampling
        EngineCli::Registry.for(cfg).render_preset
        print_setup_summary(sync(cfg))

        if @prompt.yes?("Start llama-server now?", default: true)
          restart
        else
          puts "Next: `llm restart` to launch llama-server."
        end
        cfg
      end

      def print_setup_summary(synced)
        Ui.panel(
          "LLM config saved to #{LlmConfig::LLM_CONFIG_PATH}\n" \
          "Preset written to #{Engine::Llama::PRESET_FILE}\n" \
          "Agents synced: #{synced.empty? ? 'none found' : synced.join(', ')}",
          title: "Setup complete"
        )
      end

      def wait_for_release(cfg, action)
        released = Util::Probes.wait_until(attempts: 30, delay: 1, label: "waiting for port to be released") { released?(cfg) }
        return true if released

        report(Result.error("llama-server still holds #{cfg.llama.host}:#{cfg.llama.port} -- #{action} aborted"))
        false
      end

      def released?(cfg)
        Util::Probes.find_pid_by_cmd("llama-server", exclude: Engine::ServerProcess.embed.pids).nil? &&
          Util::Probes.port_free?(cfg.llama.host, cfg.llama.port.to_i)
      end
    end
  end
end
