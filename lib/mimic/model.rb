require "pathname"
require_relative "model/schema"
require_relative "llm_config"
require_relative "paths"
require_relative "model/vram"
require_relative "model/store"
require_relative "model/header"

module Mimic
  # A GGUF on disk together with the multimodal projector that belongs to it.
  #
  # llama.cpp ships a vision model as two files: the decoder, and a projector
  # (the vision tower plus the adapter into the decoder's hidden dim) loaded
  # with --mmproj. The projector cannot run on its own, so a scan pairs it
  # onto its model rather than listing it as one.
  class Model
    N_CPU_MOE_PATH = Paths::LLM_ROOT / "ik-n-cpu-moe.json"

    class << self
      # llama.cpp's own convert/clip.cpp mark a projector GGUF with
      # general.type == "mmproj" -- naming (mmproj-prefixed, mmproj-suffixed,
      # or neither) is convention, not a contract, so the header is the only
      # reliable signal.
      def projector?(path) = Header.new(path).metadata["general.type"] == "mmproj"

      def pair(entries)
        entries.reject { |path, _scan_dir| projector?(path) }
               .map { |path, scan_dir| new(path, scan_dir) }
      end

      # The directory is the binding; stem only breaks a tie when a
      # directory holds several projectors. The glob has to run against the
      # realpath directory: ~/hf-models is a tree of per-file symlinks, and
      # a model's projector usually exists only in the target directory.
      def projector_for(model_path)
        real = Pathname.new(model_path.to_s).realpath
        candidates = Pathname.glob(real.dirname / "*.gguf").select { |c| c.file? && projector?(c) }.sort
        return nil if candidates.empty?

        stem = LlmConfig::Settings.alias_for(model_path.to_s).downcase
        candidates.find { |c| c.basename.to_s.downcase.include?(stem) } ||
          (candidates.one? ? candidates.first : nil)
      rescue SystemCallError
        nil
      end
    end

    def initialize(path, scan_dir = nil)
      @path = Pathname.new(path.to_s)
      @scan_dir = scan_dir
    end

    attr_reader :path, :scan_dir

    def real = @real ||= path.realpath
    def model_alias = @model_alias ||= LlmConfig::Settings.alias_for(path.to_s)
    def vision? = !projector.nil?
    def embedding? = @embedding ||= Schema.embedding?(real.to_s) == true

    def projector
      return @projector if defined?(@projector)

      @projector = self.class.projector_for(path)
    end

    def last_ctx
      entry = ctx_store.fetch(path.to_s)
      entry && [entry["context_length"], entry["cache_type"]]
    end

    def remember_ctx(context_length, cache_type)
      ctx_store.write(path.to_s, "context_length" => context_length, "cache_type" => cache_type)
    end

    def compute_mib(ctx, cache_type)
      (compute_store.fetch(path.to_s) || {})[compute_key(ctx, cache_type)]
    end

    def remember_compute(ctx, cache_type, mib)
      entry = compute_store.fetch(path.to_s) || {}
      entry[compute_key(ctx, cache_type)] = mib
      compute_store.write(path.to_s, entry)
    end

    # What to launch with: the values the last successful run under this
    # reasoning choice was given, or -- before there is one -- the publisher's
    # suggestion from the header over the hardcoded defaults.
    def sampling_for(reasoning:)
      last_sampling(reasoning: reasoning) || resolved_sampling
    end

    def last_sampling(reasoning:)
      entry = sampling_store.fetch(path.to_s)
      entry["values"] if entry && entry["reasoning"] == reasoning
    end

    def remember_sampling(reasoning, values)
      sampling_store.write(path.to_s, "reasoning" => reasoning, "values" => values)
    end

    def forget_sampling = sampling_store.delete(path.to_s)

    def n_cpu_moe = n_cpu_moe_store.fetch(path.to_s)
    def remember_n_cpu_moe(value) = n_cpu_moe_store.write(path.to_s, value)
    def forget_n_cpu_moe = n_cpu_moe_store.delete(path.to_s)

    # Return an estimate hash, or nil when it can't be computed (no GPU / parse fail).
    #
    # Keys: fits, need_mib, budget_mib, total_mib, weights_mib, kv_mib, max_ctx.
    def preflight(ctx, cache_type, compute_mib: nil)
      elems = Vram.kv_elems_per_token(header.metadata)
      total = Vram.gpu_total_mib
      return nil if elems.nil? || total.nil?

      compute = compute_mib || Vram.compute_default(total)
      per_tok_mib = elems * Vram::CACHE_BPE.fetch(cache_type, 2.0) / 1024 / 1024
      weights_mib = (File.size(path) + projector_bytes) / 1024.0 / 1024.0
      kv_mib = per_tok_mib * ctx
      need_mib = weights_mib + kv_mib + compute
      budget = total - Vram::DESKTOP_RESERVE_MIB
      max_ctx = per_tok_mib.zero? ? 0 : ((budget - weights_mib - compute) / per_tok_mib).to_i
      {
        fits: need_mib <= budget,
        need_mib: need_mib,
        budget_mib: budget,
        total_mib: total,
        weights_mib: weights_mib,
        kv_mib: kv_mib,
        max_ctx: [0, max_ctx].max,
      }
    rescue Errno::ENOENT, ArgumentError, EOFError
      nil
    end

    private

    def header = @header ||= Header.new(path)

    # A vision model's projector is loaded onto the GPU with --mmproj, so it
    # spends VRAM the decoder's own file size does not account for.
    def projector_bytes
      projector ? File.size(projector) : 0
    rescue SystemCallError
      0
    end

    def compute_key(ctx, cache_type) = "#{ctx}:#{cache_type}"

    def resolved_sampling
      LlmConfig::Sampling.resolve(header.metadata)
    rescue ArgumentError, SystemCallError, IOError
      LlmConfig::Sampling::DEFAULTS
    end

    def ctx_store = Store.new(LlmConfig::MODEL_CTX_PATH)
    def sampling_store = Store.new(LlmConfig::MODEL_SAMPLING_PATH)
    def compute_store = Store.new(LlmConfig::MODEL_COMPUTE_PATH)
    def n_cpu_moe_store = Store.new(N_CPU_MOE_PATH)
  end
end
