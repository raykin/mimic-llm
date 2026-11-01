require "etc"
require "pathname"
require_relative "../paths"
require_relative "binary_options"

module Mimic
  module EngineCli
    class LlamaPreset
      # Preset keys are llama.cpp's long flag names without the dashes, so the
      # same table names an entry here and, re-dashed, the flag the router
      # reports it back as in /v1/models -- see Llama::ARG_FLAGS.
      KEYS = {
        model: "model",
        ctx: "ctx-size",
        n_gpu_layers: "n-gpu-layers",
        flash_attn: "flash-attn",
        ubatch: "ubatch-size",
        cache_type: "cache-type-k",
        cache_type_v: "cache-type-v",
        threads: "threads",
        n_slots: "parallel",
        chat_template: "chat-template-file",
        mmproj: "mmproj",
        spec_draft_model: "spec-draft-model",
        spec_type: "spec-type",
        spec_draft_n_max: "spec-draft-n-max",
        reasoning: "reasoning",
        reasoning_effort: "reasoning-effort",
        load_on_startup: "load-on-startup",
      }.freeze

      # `options` is the flag surface of the binary that will read this file.
      # Nil means write every key unaudited -- the caller could not resolve a
      # binary, so there is nothing to audit against.
      def initialize(settings, model_alias:, chat_template: nil, mtp: false, mtp_drafter: nil, mmproj: nil,
                     options: nil)
        @settings = settings
        @model_alias = model_alias
        @chat_template = chat_template
        @mtp = mtp
        @mtp_drafter = mtp_drafter
        @mmproj = mmproj
        @options = options
        @dropped = []
      end

      attr_reader :dropped

      def write(path)
        @dropped = []
        body = lines.join("\n")
        path.dirname.mkpath
        path.write("#{body}\n")
        path
      end

      private

      # The router refuses to start on an unrecognized key rather than
      # ignoring it, so a key this build has never heard of is left out --
      # losing one setting beats losing the server.
      def keep?(key)
        return true if @options.nil? || @options.supports?(key)

        @dropped << key
        false
      end

      # `version` must sit under the global `[*]` section: keys above the
      # first section head become a preset literally named "default"
      # (preset.cpp maps the empty section name to
      # COMMON_PRESET_DEFAULT_NAME), and since the parser then skips
      # `version` that preset carries no model. The router advertises it
      # in /v1/models and, when a client picks it, spawns a model-less
      # child that never finishes loading.
      def lines
        ["[*]", "version = 1", "", "[#{@model_alias}]"] + entry_lines + sampling_lines
      end

      def entry_lines
        entries.filter_map do |key, value|
          name = KEYS.fetch(key)
          "#{name} = #{value}" unless value.nil? || !keep?(name)
        end
      end

      def sampling_lines
        @settings.model.sampling.to_h.filter_map { |flag, value| "#{flag} = #{value}" if keep?(flag.to_s) }
      end

      def entries
        {
          model: @settings.model.path,
          ctx: @settings.model.context_length,
          # All-GPU or nothing. Without this llama.cpp auto-fit silently
          # moves tensors to CPU to make an oversized ctx boot, and the
          # resulting PCIe traffic per ubatch costs more than the run is
          # worth. ik is the engine for deliberate CPU-MoE offload; here a
          # model that doesn't fit should fail at load.
          n_gpu_layers: 999,
          flash_attn: @settings.llama.flash_attn,
          ubatch: 1024,
          cache_type: @settings.llama.cache_type,
          cache_type_v: @settings.llama.cache_type,
          threads: Etc.nprocessors || 4,
          n_slots: @settings.llama.n_slots,
          chat_template: @chat_template,
          mmproj: @mmproj,
          spec_draft_model: (@mtp_drafter if @mtp),
          spec_type: ("draft-mtp" if @mtp),
          spec_draft_n_max: (Engine::Base::SPEC_DRAFT_N_MAX if @mtp),
          reasoning: @settings.model.reasoning,
          reasoning_effort: @settings.model.reasoning_effort,
          load_on_startup: "true",
        }
      end
    end
  end
end
