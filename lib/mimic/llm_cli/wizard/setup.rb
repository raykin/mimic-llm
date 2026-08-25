require "pathname"
require "etc"
require_relative "../../ui"
require_relative "../../util/fmt"
require_relative "../../util/host"
require_relative "../../util/probes"
require_relative "../../engine_cli"
require_relative "../../engine"
require_relative "../../model/vram"
require_relative "../../llm_config"
require_relative "../../model"

module Mimic
  module LlmCli
    module Wizard
      class Setup
        CONTEXT_PRESETS = {
          "60000 / q8_0 -- roomy, fits models 110000 can't" => [60_000, "q8_0"],
          "80000 / q8_0 -- balanced, fits most 128k models" => [80_000, "q8_0"],
          "110000 / q8_0 -- near-max all-GPU (~1.5 GB VRAM headroom)" => [110_000, "q8_0"],
          "120000 / q8_0 -- max q8_0 all-GPU (~1 GB free, desktop-tight)" => [120_000, "q8_0"],
          "131072 / q8_0 -- fastest, max all-GPU context" => [131_072, "q8_0"],
          "140000 / q8_0 -- extended ctx (verify it fits)" => [140_000, "q8_0"],
          "150000 / q8_0 -- extended ctx (verify it fits)" => [150_000, "q8_0"],
          "160000 / q8_0 -- extended ctx (verify it fits)" => [160_000, "q8_0"],
          "180000 / q8_0 -- extended ctx (verify it fits)" => [180_000, "q8_0"],
          "200000 / q8_0 -- extended ctx (verify it fits)" => [200_000, "q8_0"],
          "262144 / q4_0 -- max context, ~half speed" => [262_144, "q4_0"],
        }.freeze

        ENGINE_BLURBS = {
          "llama.cpp" => "upstream, router-mode preset",
          "ik_llama.cpp" => "ikawrakow fork (IQK quants, fused MoE)",
          "prism-llama.cpp" => "PrismML fork (Q2_0 ternary Bonsai kernels)",
        }.freeze

        ENGINE_TERNARY_PACKING = {
          "llama.cpp" => :g64,
          "prism-llama.cpp" => :g128,
        }.freeze

        attr_reader :config

        def initialize(config, total: 6, cli_name: "llm", prompt: Ui::Prompt.new)
          @config = config
          @total = total
          @cli_name = cli_name
          @prompt = prompt
          @step = 0
        end

        def step(title)
          @step += 1
          puts "\n#{Ui.bold_cyan("Step #{@step}/#{@total}")} -- #{title}"
        end

        def system_check
          step("System check")
          rows = [
            ["RAM", "#{Util::Host.total_mem_kb / 1024 / 1024} GB"],
            ["Free disk (home)", "#{Util::Host.free_home_bytes / (1024**3)} GB"],
            ["Ruby", RUBY_VERSION],
            ["GPU backend (detected)", Util::Host.backend],
            ["llama-server", Util::Host.llama_server || Ui.red("not found")],
            ["claude on PATH", Util::Probes.which("claude") || Ui.red("not found")],
          ]
          rows.each { |label, value| puts format("  %-24s %s", label, value) }
        end

        def choose_engine
          step("Inference engine")
          choices = EngineCli::Registry.names.map do |name|
            { name: [name, ENGINE_BLURBS[name]].compact.join(" -- "), value: name }
          end
          current = choices.index { |choice| choice[:value] == @config.llama.engine } || 0
          @config.llama.engine = @prompt.select("Inference engine:", choices, default: current + 1)
        end

        def ensure_binary(engine)
          step("#{engine} binary")
          @config.llama.binary = EngineCli::Builder.new(@config, cli_name: @cli_name, prompt: @prompt)
                                                   .find_or_build(engine)
        end

        def choose_model
          step("Model")
          @config.model.path = select_model(@config.model.path)
          report_hidden_models
        end

        def choose_mmproj
          step("Multi-modal projector (optional)")
          candidate = Model.projector_for(@config.model.path)
          unless candidate
            @config.model.mmproj_path = nil
            return
          end

          accepted = @prompt.yes?("Use #{candidate.basename} as projector?", default: false)
          @config.model.mmproj_path = accepted ? candidate.to_s : nil
        end

        def choose_context
          step("Context preset")
          remembered = @config.model.file.last_ctx
          if remembered
            @config.model.context_length, @config.llama.cache_type = remembered
            puts "#{Ui.green('Last good run for this model:')} #{Util::Fmt.commas(remembered[0])} / #{remembered[1]}"
          end
          loop do
            pick_context
            break if preflight_ok?
          end
          @config
        end

        def choose_reasoning
          step("Reasoning")
          wanted = @prompt.yes?("Let the model think before it answers?", default: true)
          @config.model.reasoning = wanted ? "auto" : "off"
          @config
        end

        def search_dirs
          @config.search_paths
        end

        def scan_gguf
          found = []
          seen = {}
          search_dirs.each do |directory|
            next unless directory.directory?

            Dir.glob(directory / "**/*.gguf").sort.each do |raw|
              path = Pathname.new(raw)

              # A dangling symlink still shows up in the glob; realpath is what
              # proves the model is actually there.
              real = begin
                path.realpath
              rescue SystemCallError
                next
              end
              next if seen[real]

              seen[real] = true
              found << [path, directory]
            end
          end
          Model.pair(found)
        end

        # An embedding model answers /v1/embeddings and nothing else -- it has no
        # chat template and no completions endpoint, so it belongs to `llm embed`
        # rather than to the picker that chooses what the agents talk to.
        def chat_models
          loadable, @hidden_models = scan_gguf.reject(&:embedding?).partition { |model| loadable?(model) }
          loadable
        end
        def embedding_models = scan_gguf.select(&:embedding?)

        def select_model(current)
          by_label = chat_models.to_h { |model| [model_label(model), model.path.to_s] }
          manual = "Enter a path manually..."
          answer = if by_label.any?
                     current_label = by_label.key(current)
                     @prompt.select("GGUF model file:", [*by_label.keys, manual], default: current_label)
                   else
                     manual
                   end
          answer = if answer == manual
                     @prompt.ask("Path to .gguf file:", default: current)
                   else
                     by_label.fetch(answer, answer)
                   end
          # A typed answer arrives literal -- no shell has expanded ~ for us,
          # and File.file? does not either.
          expanded = Pathname.new(answer.to_s).expand_path
          if answer.to_s.empty? || !expanded.file?
            puts Ui.red("Model file not found.")
            raise SystemExit, 1
          end
          expanded.realpath.to_s
        end

        private

        # A ternary GGUF is written for exactly one engine's block layout, and
        # the wrong one either refuses it or reads garbage -- so the picker only
        # offers the packing the chosen engine can read. ik_llama.cpp defines no
        # Q2_0 at all, hence no entry.
        #
        # prism-llama.cpp exists only to serve its own G128 ternary kernels --
        # any ordinary GGUF it could also load belongs to llama.cpp/ik_llama.cpp
        # instead, so its list narrows to G128-only rather than G128-plus-plain.
        def loadable?(model)
          packing = Model::Header.new(model.real).ternary_packing
          return packing == ENGINE_TERNARY_PACKING[@config.llama.engine] if @config.llama.engine == "prism-llama.cpp"

          packing.nil? || packing == ENGINE_TERNARY_PACKING[@config.llama.engine]
        end

        def report_hidden_models
          return if @hidden_models.nil? || @hidden_models.empty?

          names = @hidden_models.map { |model| model.path.basename.to_s }.join(", ")
          reason = if @config.llama.engine == "prism-llama.cpp"
                     "not a Prism G128 ternary model"
                   else
                     "ternary weights #{@config.llama.engine} cannot read"
                   end
          puts Ui.yellow("hidden -- #{reason}: #{names}")
        end

        def model_label(model)
          tags = []
          tags << "MoE" if Model::Header.new(model.real).moe?
          tags << "vision" if model.vision?
          suffix = tags.empty? ? "" : " [#{tags.join(', ')}]"
          "#{model.path.dirname.basename}/#{model.path.basename}#{suffix}"
        end

        def pick_context
          current_preset = CONTEXT_PRESETS.find do |_, (ctx, kv)|
            ctx == @config.model.context_length && kv == @config.llama.cache_type
          end&.first
          picked = @prompt.select("Context preset:", [*CONTEXT_PRESETS.keys, "Custom..."], default: current_preset)
          if picked == "Custom..."
            context = @prompt.ask("Context length (tokens):", default: @config.model.context_length.to_s)
            @config.model.context_length = Integer(context)
            @config.llama.cache_type = @prompt.select("KV cache type:", %w[q8_0 q4_0 f16], default: @config.llama.cache_type)
          else
            ctx, kv = CONTEXT_PRESETS.fetch(picked)
            @config.model.context_length = ctx
            @config.llama.cache_type = kv
          end
        end

        # Estimate VRAM for the chosen ctx; warn + confirm if it would over-commit.
        #
        # Returns true to accept (fits, un-checkable, or user override), false to re-pick.
        def preflight_ok?
          model = @config.model.file
          est = model.preflight(@config.model.context_length, @config.llama.cache_type,
                                compute_mib: model.compute_mib(@config.model.context_length, @config.llama.cache_type))
          return true if est.nil?

          if est[:fits]
            puts "#{Ui.green('VRAM ok')} -- needs ~#{format('%.1f', est[:need_mib] / 1024.0)} GB of " \
                 "#{format('%.1f', est[:total_mib] / 1024.0)} GB (fits to ~#{Util::Fmt.commas(est[:max_ctx])} tok)"
            return true
          end
          return true if offloaded_to_fit?(est)

          puts "#{Ui.yellow('this context won\'t fully fit VRAM.')} Needs " \
               "~#{format('%.1f', est[:need_mib] / 1024.0)} GB (weights #{format('%.1f', est[:weights_mib] / 1024.0)} + " \
               "KV #{format('%.1f', est[:kv_mib] / 1024.0)} + compute), budget ~#{format('%.1f', est[:budget_mib] / 1024.0)} GB.\n" \
               "  It will load but crash at runtime once context passes " \
               "~#{Util::Fmt.commas(est[:max_ctx])} tokens. Pick <= that, or switch KV to q4_0."
          @prompt.yes?("Use this over-committed context anyway?", default: false)
        end

        # A MoE model can trade VRAM for PCIe traffic by keeping some layers'
        # experts on the CPU, so a deficit the ceiling can cover is a setting to
        # write, not a warning to print. Only ik takes --n-cpu-moe; llama.cpp's
        # preset pins n-gpu-layers=999 on purpose.
        def offloaded_to_fit?(est)
          return false unless @config.llama.ik?

          layers = Model::Vram.layers_to_offload(@config.model.path,
                                                  deficit_mib: est[:need_mib] - est[:budget_mib],
                                                  ceiling: offload_ceiling)
          return false if layers.nil? || layers.zero?

          @config.model.file.remember_n_cpu_moe(layers)
          puts "#{Ui.green("offloading #{layers} layers of MoE experts to CPU")} -- " \
               "frees ~#{format('%.1f', (est[:need_mib] - est[:budget_mib]) / 1024.0)} GB, " \
               "so #{Util::Fmt.commas(@config.model.context_length)} tokens fits"
          true
        end

        def offload_ceiling
          layers = Model::Header.new(@config.model.path).block_count
          [Engine::IkLlama::CPU_MOE_MAX, layers || Engine::IkLlama::CPU_MOE_MAX].min
        end
      end
    end
  end
end
