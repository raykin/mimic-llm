require_relative "../llm_config"
require_relative "sampling"

module Mimic
  module LlmConfig
    # The model section: which GGUF is served and the knobs that belong to it
    # rather than to the server. `file` is the Model behind the configured
    # path -- rebuilt whenever the path changes, so nothing holds a Model for
    # a GGUF that is no longer selected.
    class ModelSettings
      SECTION = "model".freeze

      def initialize(cfg)
        @cfg = cfg
      end

      def path = section["path"]
      def context_length = section["context_length"]
      def mtp = section.fetch("mtp", "auto")
      def name = file.model_alias
      # 'auto' rather than 'on': the engine detects thinking support from the
      # chat template, so a model with no thinking mode is not forced into one
      # it cannot render.
      def reasoning = section.fetch("reasoning", "auto")

      def sampling = Sampling.new(file.memory.sampling_for(reasoning: reasoning))

      def file
        @file = Model.new(path) if @file.nil? || @file.path.to_s != path
        @file
      end

      # A remembered projector can be deleted or moved between runs, and
      # llama-server refuses to boot on a missing --mmproj, so an entry that
      # no longer resolves counts as no entry.
      def mmproj_path
        stored = @pending_mmproj_set ? @pending_mmproj : file.memory.mmproj
        stored if stored && File.exist?(stored)
      end

      def path=(value)
        writable["path"] = value
      end

      def context_length=(value)
        writable["context_length"] = value
      end

      def reasoning=(value)
        writable["reasoning"] = value
      end

      def mmproj_path=(value)
        @pending_mmproj_set = true
        @pending_mmproj = value
      end

      def save
        file.memory.mmproj = @pending_mmproj if @pending_mmproj_set
      end

      private

      # Reads see an absent section as an empty one; only a write materialises
      # it, so a hand-built config keeps the sections it actually carries.
      def section = @cfg[SECTION] || {}
      def writable = @cfg[SECTION] ||= {}
    end
  end
end
