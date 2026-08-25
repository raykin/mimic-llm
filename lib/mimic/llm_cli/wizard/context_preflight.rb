require_relative "../../ui"
require_relative "../../util/fmt"
require_relative "../../engine"
require_relative "../../model"
require_relative "../../model/footprint"
require_relative "../../model/header"

module Mimic
  module LlmCli
    module Wizard
      # Estimate VRAM for a chosen context; warn + confirm if it would
      # over-commit. llama.cpp accepts a context it cannot hold and dies once
      # the KV cache fills, so the negotiation happens here rather than at
      # launch.
      class ContextPreflight
        def initialize(config, prompt: Ui::Prompt.new)
          @config = config
          @prompt = prompt
        end

        # True to accept (fits, un-checkable, offloaded, or user override),
        # false to re-pick.
        def ok?
          est = estimate
          return true unless est.measurable?

          if est.fits?
            puts "#{Ui.green('VRAM ok')} -- needs ~#{format('%.1f', est.need_mib / 1024.0)} GB of " \
                 "#{format('%.1f', est.total_mib / 1024.0)} GB (fits to ~#{Util::Fmt.commas(est.max_ctx)} tok)"
            return true
          end
          return true if offloaded_to_fit?(est)

          warn_over_commit(est)
          @prompt.yes?("Use this over-committed context anyway?", default: false)
        end

        private

        def estimate
          model = @config.model.file
          model.footprint(ctx, cache_type, compute_mib: model.memory.compute_mib(ctx, cache_type),
                          slots: @config.llama.n_slots, reclaimable_mib: Engine::ServerProcess.chat.gpu_mib)
        end

        def ctx = @config.model.context_length
        def cache_type = @config.llama.cache_type

        # A MoE model can trade VRAM for PCIe traffic by keeping some layers'
        # experts on the CPU, so a deficit the ceiling can cover is a setting to
        # write, not a warning to print. Only ik takes --n-cpu-moe; llama.cpp's
        # preset pins n-gpu-layers=999 on purpose.
        def offloaded_to_fit?(est)
          return false unless @config.llama.ik?

          layers = est.layers_to_offload(ceiling: offload_ceiling)
          return false if layers.nil? || layers.zero?

          @config.model.file.memory.remember_n_cpu_moe(layers)
          puts "#{Ui.green("offloading #{layers} layers of MoE experts to CPU")} -- " \
               "frees ~#{format('%.1f', (est.need_mib - est.budget_mib) / 1024.0)} GB, " \
               "so #{Util::Fmt.commas(ctx)} tokens fits"
          true
        end

        def offload_ceiling
          layers = Model::Header.new(@config.model.path).block_count
          [Engine::IkLlama::CPU_MOE_MAX, layers || Engine::IkLlama::CPU_MOE_MAX].min
        end

        def warn_over_commit(est)
          puts "#{Ui.yellow('this context won\'t fully fit VRAM.')} Needs " \
               "~#{format('%.1f', est.need_mib / 1024.0)} GB (weights #{format('%.1f', est.weights_mib / 1024.0)} + " \
               "KV #{format('%.1f', est.kv_mib / 1024.0)} + compute), budget ~#{format('%.1f', est.budget_mib / 1024.0)} GB.\n" \
               "  It will load but crash at runtime once context passes " \
               "~#{Util::Fmt.commas(est.max_ctx)} tokens. Pick <= that, or switch KV to q4_0."
        end
      end
    end
  end
end
