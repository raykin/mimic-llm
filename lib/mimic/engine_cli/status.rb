require_relative "../ui"
require "json"
require_relative "../util/fmt"
require_relative "registry"
require_relative "../engine"
require_relative "../util/probes"

module Mimic
  # What `llm status` reports: the config profile, corrected by whatever the
  # running instance was actually started with.
  module EngineCli
    class Status
      SAMPLING_LABELS = { "presence-penalty" => "presence", "repeat-penalty" => "repeat" }.freeze

      def initialize(config)
        @config = config
        @engine = Registry.for(config)
      end

      def print
        running = Engine::Llama.new(@config).running?
        running ? print_running : print_stopped

        ctx, kv, n_slots = running ? live_profile : config_profile
        model_path = @config.model.path
        field("Model", model_path.empty? ? "<unset>" : File.basename(model_path))
        field("Context", "#{Util::Fmt.commas(ctx)} tokens#{slot_split(ctx, n_slots)}")
        field("KV cache", kv)
        cpu_moe = running ? cpu_moe_label : nil
        field("CPU MoE", cpu_moe) if cpu_moe
        field("Vision", vision_label(running))
        field("Reasoning", reasoning_label(running))
        field("Thinking", effort_label(running))
        field("Sampling", sampling_label(running))
        field("Binary", @config.llama.binary)
      end

      private

      # Padding goes inside the colour: an escape sequence has no printing
      # width, so formatting an already-coloured label pads by the wrong
      # amount and the values stop lining up.
      def field(label, value) = puts("#{Ui.green(format('%-10s', "#{label}:"))} #{value}")

      def vision_label(running)
        projector = (running && live_arg(:mmproj)) || @config.model.mmproj_path
        projector ? "on (#{File.basename(projector)})" : "off"
      end

      def reasoning_label(running)
        mode = (running && live_arg(:reasoning)) || @config.model.reasoning
        return mode unless mode == "auto"

        chat_template.thinks? ? "on" : "off"
      end

      def effort_label(running)
        return "off" if reasoning_label(running) == "off"

        level = (running && live_effort) || @config.model.reasoning_effort
        return level if level

        default = chat_template.default_effort
        default ? "#{default} (template default)" : "the chat template has no levels"
      end

      # llama.cpp reports --reasoning-effort; ik carries the level inside
      # --chat-template-kwargs.
      def live_effort
        live_arg(:reasoning_effort) || kwargs_effort(live_arg(:chat_template_kwargs))
      end

      def kwargs_effort(json)
        json && JSON.parse(json)["reasoning_effort"]
      rescue JSON::ParserError
        nil
      end

      def chat_template
        @chat_template ||= Engine::ChatTemplate.new(@config.model.path, model_alias: @config.model.name)
      end

      def sampling_label(running)
        configured = @config.model.sampling.to_h
        values = LlmConfig::Sampling::FLAGS.values.map do |flag|
          live = running ? live_sampling(flag) : nil
          "#{SAMPLING_LABELS.fetch(flag, flag)} #{live || configured[flag]}"
        end
        values.join("  ")
      end

      # llama.cpp's router re-emits the preset's `temp` key as `--temperature`;
      # ik's launch record keeps the `--temp` the engine was handed.
      def live_sampling(flag)
        spellings = flag == "temp" ? %w[--temp --temperature] : ["--#{flag}"]
        spellings.filter_map { |spelling| live_argv && arg_value(live_argv, spelling) }.first
      end

      def live_arg(key)
        flag = arg_flags[key]
        flag && live_argv && arg_value(live_argv, flag)
      end

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
        pid = Engine::ServerProcess.chat.pid || "?"
        field("Engine", @config.llama.engine)
        field("Status", "running at #{@config.llama.base_url} (pid #{pid})")
      end

      def print_stopped
        field("Engine", @config.llama.engine)
        field("Status", Ui.yellow("not running"))
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
