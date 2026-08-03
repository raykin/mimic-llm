require "tty-box"
require_relative "fmt"
require_relative "vram"

module Mimic
  # Pick an n_slots/ctx-per-request pair for throughput testing. Total
  # ctx-size is the product, and that is what has to fit in VRAM.
  class BenchmarkWizard
    CTX_PRESETS = {
      "2048 -- short prompts, max concurrency" => 2048,
      "4096 -- humaneval-rb-sized prompts" => 4096,
      "8192 -- moderate prompts" => 8192,
      "16000 -- long prompts" => 16_000,
    }.freeze

    SLOT_CHOICES = [1, 2, 4, 8, 16, 32].freeze

    def initialize(config, setup_wizard, prompt:, pastel:)
      @config = config
      @setup_wizard = setup_wizard
      @prompt = prompt
      @pastel = pastel
    end

    def run
      puts TTY::Box.frame("llm -- benchmark wizard", padding: 0)

      step(1, "Model")
      @config.model_path = @setup_wizard.select_model(@config.model_path)

      step(2, "Context per request")
      ctx_per_slot = choose_ctx_per_slot

      step(3, "Slots")
      n_slots = choose_slots(ctx_per_slot)

      @config.context_length = ctx_per_slot * n_slots
      @config.n_slots = n_slots
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
      est = Vram.preflight(@config.model_path, total, @config.cache_type)
      tag = est.nil? || est[:fits] ? @pastel.green("fits") : @pastel.red("too big")
      format("  %2d slots -> %10s total ctx  %s", slots, Fmt.commas(total), tag)
    end

    def step(index, title)
      puts "\n#{@pastel.bold.cyan("Step #{index}/3")} -- #{title}"
    end
  end
end
