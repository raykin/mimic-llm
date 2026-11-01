require_relative "base"
require_relative "../engine_cli/llama_preset"

module Mimic
  module Engine
    class Llama < Base
      PRESET_FILE = Paths::LLM_RUN_DIR / "llama-models.ini"

      # The launch surface is the preset file, not the argv, so these are the
      # preset's own keys re-dashed into the flags the router expands them to
      # in /v1/models. Only the three observed there are listed -- notably no
      # n_cpu_moe, which is how `llm status` knows to leave the line off.
      ARG_FLAGS = %i[ctx cache_type n_slots mmproj reasoning reasoning_effort].to_h { |key| [key, "--#{EngineCli::LlamaPreset::KEYS.fetch(key)}"] }.freeze

      # argv of the actually-running instance, straight from the router's own
      # /v1/models -- config.yaml can be stale (e.g. `llm parallel` overrides
      # ctx/slots without persisting them).
      def live_args
        data = Util::Probes.http_json(models_url)
        return nil if data.nil?

        entry = (data["data"] || []).find { |e| e["id"] == model_alias && e.dig("status", "value") == "loaded" }
        entry&.dig("status", "args")
      end

      def render_preset
        ensure_chat_template
        drafter = mtp_drafter
        preset = EngineCli::LlamaPreset.new(@settings, model_alias: model_alias, chat_template: chat_template_override,
                                                       mtp: mtp_enabled? || !drafter.nil?, mtp_drafter: drafter,
                                                       mmproj: @settings.model.mmproj_path, options: binary_options)
        preset.write(PRESET_FILE)
        report_dropped(preset.dropped)
        PRESET_FILE
      end

      def start(remember: true)
        return Result.ok("llama-server already running") if running?

        binary = find_binary
        return Result.error("llama-server binary not found -- run `mimic setup`") if binary.nil?

        missing = model_missing
        return Result.error(missing) if missing
        return port_busy_error("llama-server") unless await_port_release

        render_preset
        log_offset = process.log_size
        pid = launcher.spawn(build_command(binary))

        unless Util::Probes.wait_ready(models_url, alive: -> { Util::Probes.child_alive?(pid) }, label: "waiting for llama-server")
          process.cleanup_failed(pid)
          return Result.error("llama-server failed to start -- see #{process.log_file}\n#{process.last_lines(process.log_tail(log_offset))}")
        end

        failure = []
        instance_failed = lambda do
          reason = instance_failure(log_offset)
          failure << reason if reason
          !reason.nil?
        end

        if Util::Probes.wait_until(attempts: 120, alive: -> { Util::Probes.child_alive?(pid) },
                             label: "loading model", abort: instance_failed) { model_loaded? }
          @settings.remember_ctx if remember
          @settings.remember_sampling if remember
          record_compute(pid)
          report_template_failures
          return Result.ok("llama-server ready, model loaded (pid #{pid})")
        end

        process.cleanup_failed(pid)
        tail = process.last_lines(process.log_tail(log_offset))
        return Result.error("#{failure.first} -- see #{process.log_file}\n#{tail}") unless failure.empty?

        Result.error("model failed to load -- see #{process.log_file}\n#{tail}")
      end

      private

      def binary_options
        binary = find_binary
        binary && EngineCli::BinaryOptions.new(binary)
      end

      def mtp_drafter = (@settings.model.file.drafter unless mtp_off?)

      def report_dropped(dropped)
        return if dropped.empty?

        puts "[preset] #{@settings.llama.engine} does not carry " \
             "#{dropped.map { |name| "--#{name}" }.join(', ')} -- left out of the preset"
      end

      def build_command(binary)
        [binary, "--models-preset", PRESET_FILE.to_s, "--host", @settings.llama.host,
         "--port", @settings.llama.port.to_s, "--reuse-port", "--metrics"]
      end

      def model_loaded?
        data = Util::Probes.http_json("#{@settings.llama.base_url}/v1/models") || {}
        (data["data"] || []).any? { |entry| entry["id"] == model_alias && entry.dig("status", "value") == "loaded" }
      end

      # Why the router's model instance died, reading only this launch's log.
      #
      # The router survives its children, so a child that OOMs looks
      # identical to one still loading: the poll that checks for it
      # triggers another autoload, and the pair loop until the caller's
      # attempts run out. The child's exit is only ever reported in the
      # shared log.
      def instance_failure(log_offset)
        tail = process.log_tail(log_offset)
        return nil unless tail.include?("instance name=#{model_alias} exited with status 1")

        if tail.include?("cudaMalloc failed: out of memory") || tail.include?("failed to allocate")
          return "#{model_alias} ran out of VRAM at #{@settings.model.context_length} ctx -- lower the context"
        end

        "#{model_alias} instance exited during load"
      end
    end
  end
end
