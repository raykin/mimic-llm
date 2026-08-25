require_relative "../ui"
require_relative "../util/fmt"
require_relative "registry"
require_relative "../engine"
require_relative "../util/probes"

module Mimic
  # What `llm status` reports: the config profile, corrected by whatever the
  # running instance was actually started with.
  module EngineCli
    class Status
      def initialize(config)
        @config = config
        @engine = Registry.for(config)
      end

      def print
        running = Engine::Llama.new(@config).running?
        running ? print_running : print_stopped

        ctx, kv, n_slots = running ? live_profile : config_profile
        model_path = @config.model.path
        puts "Model:    #{model_path.empty? ? '<unset>' : File.basename(model_path)}"
        puts "Context:  #{Util::Fmt.commas(ctx)} tokens#{slot_split(ctx, n_slots)}"
        puts "KV cache: #{kv}"
        cpu_moe = running ? cpu_moe_label : nil
        puts "CPU MoE:  #{cpu_moe}" if cpu_moe
        puts "Binary:   #{@config.llama.binary}"
      end

      private

      def arg_flags = @engine.class::ARG_FLAGS

      def live_argv
        return @live_argv if defined?(@live_argv)

        @live_argv = @engine.live_args
      end

      def config_profile = [@config.model.context_length, @config.llama.cache_type, @config.llama.n_slots]

      def live_profile
        ctx, kv, n_slots = config_profile
        argv = live_argv
        unless argv
          puts Ui.yellow("  (couldn't confirm live ctx/slots from server -- showing config.yaml, may be stale)")
          return [ctx, kv, n_slots]
        end

        [(arg_value(argv, arg_flags[:ctx]) || ctx).to_i,
         arg_value(argv, arg_flags[:cache_type]) || kv,
         (arg_value(argv, arg_flags[:n_slots]) || n_slots).to_i]
      end

      # Only the engine that can offload experts reports the line, and only
      # from the argv it really launched with -- the cached value is what the
      # next start would use, not what this instance is running.
      def cpu_moe_label
        flag = arg_flags[:n_cpu_moe]
        return nil unless flag && live_argv

        layers = arg_value(live_argv, flag).to_i
        layers.positive? ? "#{layers} layers offloaded" : "none (all layers on GPU)"
      end

      def print_running
        pid = Engine::Base.pid_file.exist? ? Engine::Base.pid_file.read.strip : "?"
        puts "#{Ui.green('Engine:')} #{@config.llama.engine}"
        puts "#{Ui.green('Status:')} running at #{@config.llama.base_url} (pid #{pid})"
      end

      def print_stopped
        puts "#{Ui.yellow('Engine:')} #{@config.llama.engine}"
        puts "#{Ui.yellow('Status:')} not running"
      end

      def slot_split(ctx, n_slots)
        return "" unless n_slots > 1

        "  (#{n_slots} x #{Util::Fmt.commas(n_slots.positive? ? ctx / n_slots : ctx)})"
      end

      def arg_value(argv, flag)
        idx = argv.index(flag)
        idx ? argv[idx + 1] : nil
      end
    end
  end
end
