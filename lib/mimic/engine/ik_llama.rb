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

      # Tokens the MTP head drafts per verification pass. Matches the
      # llama.cpp preset's spec_draft_n_max so a cross-engine tok/s
      # comparison measures the engine, not the draft depth.
      SPEC_DRAFT_N_MAX = 2

      OOM_MARKERS = ["cudaMalloc failed", "out of memory"].freeze
      BIND_MARKER = "couldn't bind to server socket"
      KV_OOM_MARKER = "failed to allocate buffer for kv cache"

      # ik builds the MTP draft context against the target model after the
      # weights and KV are already resident, and it is not in the footprint
      # estimate -- so the stage can be what tips a load that would otherwise
      # have fit. Recoverable: the same argv minus --spec-type starts.
      MTP_OOM_MARKER = "failed to create MTP context"

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
          bind_failure = tail[/#{Regexp.escape(BIND_MARKER)}.*?port=(\d+)/m, 1]
          return "port #{bind_failure} is still held by another process" if bind_failure
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
        spec_type: "--spec-type",
        cuda: "-cuda",
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

      # `n_cpu_moe:` forces the offload the first attempt uses, in place of the
      # cache/preflight maximum below. It exists for `llm quality`, which
      # scores every model at one context on a fully resident card so its
      # numbers compare engines rather than offload depths -- an ordinary
      # `llm start` passes nothing and keeps sizing itself. The OOM retry loop
      # still escalates from it, so a forced 0 that genuinely does not fit
      # recovers instead of failing.
      def start(remember: true, n_cpu_moe: nil)
        return Result.ok("ik_llama server already running") if running?

        binary = find_binary
        return Result.error("ik_llama llama-server not found -- run `mimic setup`") if binary.nil?

        missing = model_missing
        return Result.error(missing) if missing

        model_path = @settings.model.path.to_s
        @drafting = mtp_enabled?
        if @drafting && drafting_costs_offload?(model_path)
          puts "[ik_llama] MTP would push the experts off the card at this context -- serving undrafted instead"
          @drafting = false
        end
        forced = n_cpu_moe
        n_cpu_moe = forced || [@settings.model.file.memory.n_cpu_moe || 0,
                               preflight_offload(model_path, drafting: @drafting)].max
        loop do
          return port_busy_error("ik_llama server") unless await_port_release

          puts "[ik_llama] offloading MoE experts of first #{n_cpu_moe} layers to CPU" if n_cpu_moe.positive?
          pid = launch(binary, n_cpu_moe)
          if Util::Probes.wait_ready(models_url, alive: -> { Util::Probes.child_alive?(pid) }, label: "waiting for ik_llama server")
            # The store is a ratchet the user's real setup reads back, and a
            # forced value is a caller's choice rather than a measurement --
            # recording it would silently undo an offload a bigger context
            # depends on.
            @settings.model.file.memory.remember_n_cpu_moe(n_cpu_moe) if forced.nil?
            @settings.remember_ctx if remember
            @settings.remember_sampling if remember
            record_compute(pid)
            report_template_failures
            return Result.ok("ik_llama server ready (pid #{pid})")
          end

          tail = process.log_tail
          process.cleanup_failed(pid)

          # Checked ahead of retry_blocker: this failure carries the same
          # "out of memory" the blocker keys on, and it would answer with the
          # offload verdict for a model whose experts are not the problem.
          if @drafting && tail.include?(MTP_OOM_MARKER)
            puts "[ik_llama] no VRAM left for the MTP draft context -- restarting without speculative decoding"
            @drafting = false
            next
          end

          blocker = self.class.retry_blocker(tail, n_cpu_moe)
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
      def preflight_offload(model_path, drafting: false)
        model = @settings.model.file
        ctx = @settings.model.context_length
        cache_type = @settings.llama.cache_type
        estimate = model.footprint(ctx, cache_type, compute_mib: model.memory.compute_mib(ctx, cache_type),
                                                    drafting: drafting, slots: @settings.llama.n_slots,
                                                    reclaimable_mib: process.gpu_mib,
                                                    mmproj_path: @settings.model.mmproj_path)
        return 0 if !estimate.measurable? || estimate.fits?

        ceiling = [CPU_MOE_MAX, Model::Header.new(model_path).block_count || CPU_MOE_MAX].min
        estimate.layers_to_offload(ceiling: ceiling) || 0
      end

      # Drafting is only worth having when it is free of offload.
      #
      # MTP accepts ~87% of what it drafts and is worth +27-37% decode at a
      # fixed offload, but its second context costs a nextn KV plus a whole
      # duplicate compute buffer -- 1148 MiB on Qwen3.6-35B-A3B at ctx
      # 163840. When that is what tips the model off the card, the experts it
      # displaces cost more than the drafting returns: measured 2026-08-23 at
      # that context, 82-88 tok/s undrafted with everything resident against
      # 67-68 tok/s drafting with 16 layers of experts on the CPU.
      def drafting_costs_offload?(model_path)
        return true if preflight_offload(model_path, drafting: true) > preflight_offload(model_path, drafting: false)

        # Fitting on paper is not enough. The draft context's compute buffer
        # is one contiguous cudaMalloc the size of the target's, so a launch
        # that clears the budget by less than that still dies with
        # "allocating 978.00 MiB on device 0: cudaMalloc failed" -- observed
        # at ctx 163840, where the estimate had ~600 MiB spare.
        estimate = drafting_estimate
        return false unless estimate&.measurable?

        estimate.headroom_mib < estimate.compute_mib
      end

      def drafting_estimate
        ctx = @settings.model.context_length
        cache_type = @settings.llama.cache_type
        model = @settings.model.file
        model.footprint(ctx, cache_type, compute_mib: model.memory.compute_mib(ctx, cache_type), drafting: true,
                                     slots: @settings.llama.n_slots, reclaimable_mib: process.gpu_mib,
                                     mmproj_path: @settings.model.mmproj_path)
      end

      def build_command(binary, n_cpu_moe = 0)
        flagged = launch_values(n_cpu_moe).flat_map do |key, value|
          value.nil? ? [] : [ARG_FLAGS.fetch(key), value.to_s]
        end
        # ik defaults parallel tool calls off and, unlike mainline, never
        # probes the chat template for the capability -- without this the
        # grammar allows exactly one tool call and generation ends there.
        [binary, *flagged, "--jinja", "--metrics", "-ptcall", *@settings.model.sampling.to_args]
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
          # ik packs the stage's parameters into the value, where mainline
          # spells the same thing as `draft-mtp` plus a separate
          # --spec-draft-n-max. Its other stage types all want a draft model
          # or a corpus; mtp is the only one the GGUF alone can feed.
          spec_type: ("mtp:n_max=#{SPEC_DRAFT_N_MAX}" if drafting?),
          # Workaround for ik_llama#1232 (open): ik caches one CUDA graph per
          # distinct compute graph and never evicts, so VRAM climbs ~44 MiB/min
          # under sustained load until the server dies mid-run. Measured here:
          # +2440 MiB over 56 min with graphs on, +0 over 10 min with them off.
          # The author suggested this flag and has not landed a real fix;
          # mainline's LRU eviction (ggml-org/llama.cpp#21611) is not ported.
          # Costs ~10% token generation -- drop this once ik evicts.
          cuda: "graphs=0",
        }
      end

      # render_preset runs outside start (`llm status`, preset rendering), so
      # the launch-time override has to fall back to the configured answer.
      def drafting? = defined?(@drafting) ? @drafting : mtp_enabled?

      def launch(binary, n_cpu_moe)
        render_preset(n_cpu_moe)
        launcher.spawn(build_command(binary, n_cpu_moe))
      end
    end
  end
end
