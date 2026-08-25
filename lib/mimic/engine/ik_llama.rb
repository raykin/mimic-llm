require_relative "../model"
require_relative "base"

module Mimic
  module Engine
    class IkLlama < Base
      LAUNCH_RECORD = Paths::LLM_RUN_DIR / "ik-llama-launch.txt"
      TRACE_LOG_BASE = Paths::LLM_RUN_DIR / "ik_llama"

      # Layers offloaded to CPU on each retry after an OOM, and the ceiling
      # we give up at -- generous enough for any current MoE GGUF's layer
      # count.
      CPU_MOE_STEP = 2
      CPU_MOE_MAX = 28

      OOM_MARKERS = ["cudaMalloc failed", "out of memory"].freeze
      KV_OOM_MARKER = "failed to allocate buffer for kv cache"

      class << self
        def meta_int(tail, key)
          match = tail.match(/^llm_load_print_meta: #{Regexp.escape(key)}\s*= (\d+)$/)
          match && match[1].to_i
        end

        # Why bumping --n-cpu-moe cannot rescue this failure, if it can't.
        #
        # The flag only relocates MoE expert tensors, so it is useless on a
        # dense model and cannot shrink a KV cache. Retrying regardless just
        # reloads the weights until the ceiling, which on a dense model means
        # every attempt is byte-identical to the one that already failed.
        def retry_blocker(tail, n_cpu_moe)
          return "startup failed for a reason other than VRAM" unless OOM_MARKERS.any? { |m| tail.include?(m) }
          return "this model is dense, so it has no experts to offload" if meta_int(tail, "n_expert") == 0

          n_layer = meta_int(tail, "n_layer")
          ceiling = [CPU_MOE_MAX, n_layer || CPU_MOE_MAX].min
          return nil if n_cpu_moe < ceiling

          return "the KV cache does not fit -- lower `model.context_length`" if tail.include?(KV_OOM_MARKER)

          "every layer is already offloaded (ceiling #{ceiling})"
        end
      end

      # Every flag mimic sets, in argv order: `build_command` spells them from
      # here and `ServerStatus` reads a launched argv back through the same
      # table. Valueless switches stay out of it -- there is nothing to read.
      ARG_FLAGS = {
        model: "-m",
        model_alias: "-a",
        ctx: "-c",
        flash_attn: "-fa",
        cache_type: "-ctk",
        cache_type_v: "-ctv",
        n_gpu_layers: "-ngl",
        ubatch: "-ub",
        cram: "-cram",
        n_slots: "-np",
        host: "--host",
        port: "--port",
        log_file: "--log-file",
        reasoning: "--reasoning",
        chat_template: "--chat-template-file",
        mmproj: "--mmproj",
        n_cpu_moe: "--n-cpu-moe",
      }.freeze

      # ik's server answers /v1/models without llama.cpp's router extensions,
      # so status.args is not there to read -- the argv it was launched with
      # is only on disk, in the record written beside the log.
      def live_args
        LAUNCH_RECORD.read.split
      rescue SystemCallError
        nil
      end

      def render_preset(n_cpu_moe = 0)
        ensure_chat_template
        binary = find_binary || "llama-server"
        Paths::LLM_RUN_DIR.mkpath
        LAUNCH_RECORD.write("#{build_command(binary, n_cpu_moe).join(' ')}\n")
        LAUNCH_RECORD
      end

      def start(remember: true)
        return Result.ok("ik_llama server already running") if running?

        binary = find_binary
        return Result.error("ik_llama llama-server not found -- run `mimic setup`") if binary.nil?

        missing = model_missing
        return Result.error(missing) if missing

        if mtp_enabled?
          puts "[ik_llama] MTP requested but not yet wired for ik_llama -- starting without it"
        end

        model_path = @settings.model.path.to_s
        n_cpu_moe = [@settings.model.file.memory.n_cpu_moe || 0, preflight_offload(model_path)].max
        loop do
          puts "[ik_llama] offloading MoE experts of first #{n_cpu_moe} layers to CPU" if n_cpu_moe.positive?
          pid = launch(binary, n_cpu_moe)
          if Util::Probes.wait_ready(models_url, alive: -> { Util::Probes.child_alive?(pid) }, label: "waiting for ik_llama server")
            @settings.model.file.memory.remember_n_cpu_moe(n_cpu_moe)
            @settings.remember_ctx if remember
            @settings.remember_sampling if remember
            record_compute(pid)
            report_template_failures
            return Result.ok("ik_llama server ready (pid #{pid})")
          end

          tail = process.log_tail
          blocker = self.class.retry_blocker(tail, n_cpu_moe)
          process.cleanup_failed(pid)
          if blocker
            return Result.error("ik_llama server failed to start -- #{blocker}. See #{process.log_file}\n#{process.last_lines(tail)}")
          end
          ceiling = [CPU_MOE_MAX, self.class.meta_int(tail, "n_layer") || CPU_MOE_MAX].min
          n_cpu_moe = [n_cpu_moe + CPU_MOE_STEP, ceiling].min
        end
      end

      private

      # The retry loop below only reacts to a launch that fails outright, but
      # an over-committed context loads and then dies once the KV cache
      # fills -- so the cache stays pinned at whatever last started. Ask the
      # estimate up front instead of waiting for a crash that never reaches
      # the loop.
      def preflight_offload(model_path)
        model = @settings.model.file
        ctx = @settings.model.context_length
        cache_type = @settings.llama.cache_type
        estimate = model.footprint(ctx, cache_type, compute_mib: model.memory.compute_mib(ctx, cache_type))
        return 0 if !estimate.measurable? || estimate.fits?

        ceiling = [CPU_MOE_MAX, Model::Header.new(model_path).block_count || CPU_MOE_MAX].min
        estimate.layers_to_offload(ceiling: ceiling) || 0
      end

      def build_command(binary, n_cpu_moe = 0)
        flagged = launch_values(n_cpu_moe).flat_map do |key, value|
          value.nil? ? [] : [ARG_FLAGS.fetch(key), value.to_s]
        end
        [binary, *flagged, "--jinja", "--metrics", *@settings.model.sampling.to_args]
      end

      def launch_values(n_cpu_moe)
        {
          model: @settings.model.path,
          model_alias: model_alias,
          ctx: @settings.model.context_length,
          flash_attn: @settings.llama.flash_attn,
          cache_type: @settings.llama.cache_type,
          cache_type_v: @settings.llama.cache_type,
          n_gpu_layers: 999,
          ubatch: 1024,
          cram: 2048,
          n_slots: @settings.llama.n_slots,
          host: @settings.llama.host,
          port: @settings.llama.port,
          # ik_llama's logger (llama.cpp's pre-revamp common/log.h) otherwise
          # writes a bare "llama.log" into the cwd. Name it for the engine and
          # put it beside the server log. Takes a path without the extension.
          log_file: TRACE_LOG_BASE,
          reasoning: @settings.model.reasoning,
          chat_template: chat_template_override,
          mmproj: @settings.model.mmproj_path,
          n_cpu_moe: (n_cpu_moe if n_cpu_moe.positive?),
        }
      end

      def launch(binary, n_cpu_moe)
        render_preset(n_cpu_moe)
        launcher.spawn(build_command(binary, n_cpu_moe))
      end
    end
  end
end
