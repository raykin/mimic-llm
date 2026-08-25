require "pathname"
require "etc"
require_relative "../../ui"
require_relative "../../util/fmt"
require_relative "../../util/host"
require_relative "../../util/probes"
require_relative "../../engine_cli"
require_relative "../../engine"
require_relative "context_preflight"
require_relative "../../model/library"
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
          remembered = @config.model.file.memory.last_ctx
          if remembered
            @config.model.context_length, @config.llama.cache_type = remembered
            puts "#{Ui.green('Last good run for this model:')} #{Util::Fmt.commas(remembered[0])} / #{remembered[1]}"
          end
          preflight = ContextPreflight.new(@config, prompt: @prompt)
          loop do
            pick_context
            break if preflight.ok?
          end
          @config
        end

        def choose_reasoning
          step("Reasoning")
          wanted = @prompt.yes?("Let the model think before it answers?", default: true)
          @config.model.reasoning = wanted ? "auto" : "off"
          @config
        end

        def select_model(current)
          by_label = library.chat.to_h { |model| [model_label(model), model.path.to_s] }
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

        def library
          @library ||= Model::Library.new(@config)
        end

        def report_hidden_models
          return if library.hidden.empty?

          names = library.hidden.map { |model| model.path.basename.to_s }.join(", ")
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
      end
    end
  end
end
