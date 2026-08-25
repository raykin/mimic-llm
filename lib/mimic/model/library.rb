require "pathname"
require_relative "../model"
require_relative "header"

module Mimic
  class Model
    # Every GGUF under the configured search paths, sorted into what the
    # configured engine can chat with, what `llm embed` owns, and what the
    # engine's ternary packing rules leave out.
    class Library
      # A ternary GGUF is written for exactly one engine's block layout, and
      # the wrong one either refuses it or reads garbage -- so the picker only
      # offers the packing the chosen engine can read. ik_llama.cpp defines no
      # Q2_0 at all, hence no entry.
      ENGINE_TERNARY_PACKINGS = {
        "llama.cpp" => %i[g64],
        "prism-v7-llama.cpp" => %i[pq2 ptq1],
      }.freeze

      def initialize(config)
        @config = config
      end

      def all
        @all ||= scan
      end

      def chat = partitioned.first

      # An embedding model answers /v1/embeddings and nothing else -- it has no
      # chat template and no completions endpoint, so it belongs to `llm embed`
      # rather than to the picker that chooses what the agents talk to.
      def embedding = all.select(&:embedding?)

      def chat_loadable_or_hidden = all.reject(&:embedding?)

      def hidden = partitioned.last

      # Why this model is not in the picker, for the caller that reports it.
      # Kept next to `loadable?` so the two cannot drift into explaining
      # different rules.
      # Packing first: an engine that cannot read the weights at all outranks
      # a judgement about which engine serves them faster.
      def hidden_reason(model)
        return "not a Prism Bonsai 2 ternary model" if prism_engine?
        return "ternary weights #{@config.llama.engine} cannot read" unless packing_readable?(model)
        return "MoE I-quant -- ik_llama.cpp has the kernels and the offload" if iquant_moe_under_llama?(model)

        "dense -- llama.cpp serves these faster"
      end

      private

      def partitioned
        @partitioned ||= chat_loadable_or_hidden.partition { |model| loadable?(model) }
      end

      # The Prism engine exists only to serve its own ternary kernels --
      # any ordinary GGUF it could also load belongs to llama.cpp/ik_llama.cpp
      # instead, so its list narrows to its own packing types.
      # ik_llama.cpp earns its place on MoE weights, where --n-cpu-moe puts
      # experts on the CPU and nothing else here can. On a dense model that
      # lever is inert and mainline wins outright -- measured on
      # Qwen3.8-27B-UD-Q4_K_XL, 25.6-29.6 tok/s here against 50.1-51.2 on
      # llama.cpp at the same ctx and quant, same quality score. Dense SWA
      # models are worse still: ik has no windowed KV cache, so gemma-4-31B
      # wants an order of magnitude more KV here than on mainline.
      def dense_under_ik?(model)
        @config.llama.engine == "ik_llama.cpp" && !model.moe?
      end

      # A mainline I-quant on MoE weights is ik_llama.cpp's combination and
      # mainline does not offer it. ik carries a dedicated CPU GEMM for that
      # quant family (iqk_gemm_iquants.cpp, plus _R4/_R8 repacks) and
      # --n-cpu-moe is what puts the weights in host RAM where those kernels
      # run -- the two halves only engage together, and together they are what
      # makes the big context reachable at all. Neither is on mainline: the
      # IQ kernels are CPU-side and ik's CUDA path (iqk_mmvq.cu) does not
      # touch the mainline IQ ids, so a fully resident run is unaffected.
      def iquant_moe_under_llama?(model)
        @config.llama.engine == "llama.cpp" && model.moe? && model.memory.iquant?
      end

      def loadable?(model)
        return false if dense_under_ik?(model)
        return false if iquant_moe_under_llama?(model)

        packing_readable?(model)
      end

      def packing_readable?(model)
        packing = model.memory.ternary_packing
        supported = ENGINE_TERNARY_PACKINGS[@config.llama.engine] || []
        return supported.include?(packing) if prism_engine?

        packing.nil? || supported.include?(packing)
      end

      def prism_engine? = @config.llama.engine == "prism-v7-llama.cpp"

      def scan
        found = []
        seen = {}
        @config.search_paths.each do |directory|
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
    end
  end
end
