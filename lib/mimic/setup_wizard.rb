require "pathname"
require "etc"
require "tty-prompt"
require "pastel"
require_relative "engine_builder"
require_relative "fmt"
require_relative "host"
require_relative "llm_config"
require_relative "probes"
require_relative "vram"
require_relative "services/ik_llama"
require_relative "services/llama"
require_relative "services/engine"

module Mimic
  class SetupWizard
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

    attr_reader :config

    def initialize(config, total: 5, cli_name: "llm", prompt: TTY::Prompt.new, pastel: Pastel.new)
      @config = config
      @total = total
      @cli_name = cli_name
      @prompt = prompt
      @pastel = pastel
      @step = 0
    end

    def step(title)
      @step += 1
      puts "\n#{@pastel.bold.cyan("Step #{@step}/#{@total}")} -- #{title}"
    end

    def system_check
      step("System check")
      rows = [
        ["RAM", "#{Host.total_mem_kb / 1024 / 1024} GB"],
        ["Free disk (home)", "#{Host.free_home_bytes / (1024**3)} GB"],
        ["Ruby", RUBY_VERSION],
        ["GPU backend (detected)", Host.backend],
        ["llama-server", Host.llama_server || @pastel.red("not found")],
        ["claude on PATH", Probes.which("claude") || @pastel.red("not found")],
      ]
      rows.each { |label, value| puts format("  %-24s %s", label, value) }
    end

    def choose_engine
      step("Inference engine")
      engine = @prompt.select(
        "Inference engine:",
        [
          { name: "llama.cpp -- upstream, router-mode preset", value: "llama.cpp" },
          { name: "ik_llama.cpp -- ikawrakow fork (IQK quants, fused MoE)", value: "ik_llama.cpp" },
        ],
        default: @config.engine == "ik_llama.cpp" ? 2 : 1
      )
      @config.binary = "" if engine != @config.engine
      @config.engine = engine
    end

    def ensure_binary(engine)
      step("#{engine} binary")
      @config.binary = EngineBuilder.new(@config, cli_name: @cli_name, prompt: @prompt, pastel: @pastel)
                                    .find_or_build(engine)
    end

    def choose_model
      step("Model")
      @config.model_path = select_model(@config.model_path)
    end

    def choose_context
      step("Context preset")
      remembered = LlmConfig.recall_ctx(@config.model_path)
      if remembered
        @config.context_length, @config.cache_type = remembered
        puts "#{@pastel.green('Last good run for this model:')} #{Fmt.commas(remembered[0])} / #{remembered[1]}"
      end
      loop do
        pick_context
        break if preflight_ok?
      end
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
          next if path.basename.to_s.start_with?("mmproj-")

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
      found
    end

    def select_model(current)
      by_label = scan_gguf.to_h { |p, _| [model_label(p), p.to_s] }
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
        puts @pastel.red("Model file not found.")
        raise SystemExit, 1
      end
      expanded.realpath.to_s
    end

    private

    def model_label(path)
      moe = Vram.moe?(path.realpath.to_s)
      tag = moe ? " [MoE]" : ""
      "#{path.dirname.basename}/#{path.basename}#{tag}"
    end

    def pick_context
      current_preset = CONTEXT_PRESETS.find do |_, (ctx, kv)|
        ctx == @config.context_length && kv == @config.cache_type
      end&.first
      picked = @prompt.select("Context preset:", [*CONTEXT_PRESETS.keys, "Custom..."], default: current_preset)
      if picked == "Custom..."
        context = @prompt.ask("Context length (tokens):", default: @config.context_length.to_s)
        @config.context_length = Integer(context)
        @config.cache_type = @prompt.select("KV cache type:", %w[q8_0 q4_0 f16], default: @config.cache_type)
      else
        ctx, kv = CONTEXT_PRESETS.fetch(picked)
        @config.context_length = ctx
        @config.cache_type = kv
      end
    end

    # Estimate VRAM for the chosen ctx; warn + confirm if it would over-commit.
    #
    # Returns true to accept (fits, un-checkable, or user override), false to re-pick.
    def preflight_ok?
      est = Vram.preflight(@config.model_path, @config.context_length, @config.cache_type)
      return true if est.nil?

      if est[:fits]
        puts "#{@pastel.green('VRAM ok')} -- needs ~#{format('%.1f', est[:need_mib] / 1024.0)} GB of " \
             "#{format('%.1f', est[:total_mib] / 1024.0)} GB (fits to ~#{Fmt.commas(est[:max_ctx])} tok)"
        return true
      end
      puts "#{@pastel.yellow('this context won\'t fully fit VRAM.')} Needs " \
           "~#{format('%.1f', est[:need_mib] / 1024.0)} GB (weights #{format('%.1f', est[:weights_mib] / 1024.0)} + " \
           "KV #{format('%.1f', est[:kv_mib] / 1024.0)} + compute), budget ~#{format('%.1f', est[:budget_mib] / 1024.0)} GB.\n" \
           "  It will load but crash at runtime once context passes " \
           "~#{Fmt.commas(est[:max_ctx])} tokens. Pick <= that, or switch KV to q4_0."
      @prompt.yes?("Use this over-committed context anyway?") { |q| q.default false }
    end
  end
end
