require_relative "../../ui"
require_relative "../../util/fmt"
require_relative "../../model/footprint"

module Mimic
  module LlmCli
    module Wizard
      # Pick an n_slots/ctx-per-request pair so the server can hold several
      # requests at once. Total ctx-size is the product, and that is what has
      # to fit in VRAM.
      class Parallel
        CTX_PRESETS = {
          "2048 -- short prompts, max concurrency" => 2048,
          "4096 -- humaneval-rb-sized prompts" => 4096,
          "8192 -- moderate prompts" => 8192,
          "16000 -- long prompts" => 16_000,
        }.freeze

        SLOT_CHOICES = [1, 2, 4, 8, 16, 32].freeze

        def initialize(config, setup_wizard, prompt: Ui::Prompt.new)
          @config = config
          @setup_wizard = setup_wizard
          @prompt = prompt
        end

        def run
          Ui.banner("llm -- parallel wizard")

          step(1, "Model")
          @config.model.path = @setup_wizard.select_model(@config.model.path)

          step(2, "Context per request")
          ctx_per_slot = choose_ctx_per_slot

          step(3, "Slots")
          n_slots = choose_slots(ctx_per_slot)

          @config.model.context_length = ctx_per_slot * n_slots
          @config.llama.n_slots = n_slots
          @config
        end

        private

        def choose_ctx_per_slot
          picked = @prompt.select("Context per request:", [*CTX_PRESETS.keys, "Custom..."])
          return CTX_PRESETS.fetch(picked) unless picked == "Custom..."

          Integer(@prompt.ask("Context per request (tokens):", default: "4096"))
        end

        def choose_slots(ctx_per_slot)
          puts "Total ctx-size = context-per-request x slots -- that's what has to fit in VRAM alongside the weights."
          SLOT_CHOICES.each { |slots| puts fit_line(ctx_per_slot, slots) }
          Integer(@prompt.select("n_slots:", SLOT_CHOICES.map(&:to_s), default: "8"))
        end

        def fit_line(ctx_per_slot, slots)
          total = ctx_per_slot * slots
          model = @config.model.file
          est = model.footprint(total, @config.llama.cache_type,
                                compute_mib: model.memory.compute_mib(total, @config.llama.cache_type),
                                slots: slots, reclaimable_mib: Engine::ServerProcess.chat.gpu_mib,
                                mmproj_path: @config.model.mmproj_path)
          tag = !est.measurable? || est.fits? ? Ui.green("fits") : Ui.red("too big")
          format("  %2d slots -> %10s total ctx  %s", slots, Util::Fmt.commas(total), tag)
        end

        def step(index, title)
          puts "\n#{Ui.bold_cyan("Step #{index}/3")} -- #{title}"
        end
      end
    end
  end
end
