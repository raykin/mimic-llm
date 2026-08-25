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
      ENGINE_TERNARY_PACKING = {
        "llama.cpp" => :g64,
        "prism-llama.cpp" => :g128,
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

      def hidden = partitioned.last

      private

      def partitioned
        @partitioned ||= all.reject(&:embedding?).partition { |model| loadable?(model) }
      end

      # prism-llama.cpp exists only to serve its own G128 ternary kernels --
      # any ordinary GGUF it could also load belongs to llama.cpp/ik_llama.cpp
      # instead, so its list narrows to G128-only rather than G128-plus-plain.
      def loadable?(model)
        packing = model.memory.ternary_packing
        return packing == ENGINE_TERNARY_PACKING[@config.llama.engine] if @config.llama.engine == "prism-llama.cpp"

        packing.nil? || packing == ENGINE_TERNARY_PACKING[@config.llama.engine]
      end

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
