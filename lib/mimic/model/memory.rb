require_relative "header"
require_relative "store"
require_relative "../llm_config"

module Mimic
  class Model
    # What the last good run of one model used: context, measured compute
    # buffer, sampler values, MoE offload and projector. Five sidecar JSON
    # files under ~/.llm, each keyed by resolved model path.
    class Memory
      N_CPU_MOE_PATH = Paths::LLM_ROOT / "ik-n-cpu-moe.json"
      TERNARY_PACKING_PATH = Paths::LLM_ROOT / "model-packing.json"

      def initialize(path, header = Header.new(path))
        @path = path.to_s
        @header = header
      end

      def last_ctx
        entry = ctx_store.fetch(@path)
        entry && [entry["context_length"], entry["cache_type"]]
      end

      def remember_ctx(context_length, cache_type)
        ctx_store.write(@path, "context_length" => context_length, "cache_type" => cache_type)
      end

      def compute_mib(ctx, cache_type)
        (compute_store.fetch(@path) || {})[compute_key(ctx, cache_type)]
      end

      def remember_compute(ctx, cache_type, mib)
        entry = compute_store.fetch(@path) || {}
        entry[compute_key(ctx, cache_type)] = mib
        compute_store.write(@path, entry)
      end

      # What to launch with: the values the last successful run under this
      # reasoning choice was given, or -- before there is one -- the publisher's
      # suggestion from the header over the hardcoded defaults.
      def sampling_for(reasoning:)
        last_sampling(reasoning: reasoning) || resolved_sampling
      end

      def last_sampling(reasoning:)
        entry = sampling_store.fetch(@path)
        entry["values"] if entry && entry["reasoning"] == reasoning
      end

      def remember_sampling(reasoning, values)
        sampling_store.write(@path, "reasoning" => reasoning, "values" => values)
      end

      def forget_sampling = sampling_store.delete(@path)

      def n_cpu_moe = n_cpu_moe_store.fetch(@path)
      def remember_n_cpu_moe(value) = n_cpu_moe_store.write(@path, value)
      def forget_n_cpu_moe = n_cpu_moe_store.delete(@path)

      # The packing lives in the tensor block, which sits behind the vocab
      # array -- reaching it costs a full KV walk per model, and the setup
      # picker asks for every model it lists. Cached against size and mtime so
      # a rebuilt or replaced file is re-read.
      def ternary_packing
        stamp = file_stamp
        return @header.ternary_packing if stamp.nil?

        entry = packing_store.fetch(@path)
        return entry["packing"]&.to_sym if entry && entry.slice("size", "mtime") == stamp

        packing = @header.ternary_packing
        packing_store.write(@path, stamp.merge("packing" => packing&.to_s))
        packing
      end

      def mmproj = mmproj_store.fetch(@path)

      def mmproj=(value)
        value.nil? ? mmproj_store.delete(@path) : mmproj_store.write(@path, value)
      end

      private

      def compute_key(ctx, cache_type) = "#{ctx}:#{cache_type}"

      def file_stamp
        stat = File.stat(@path)
        { "size" => stat.size, "mtime" => stat.mtime.to_i }
      rescue SystemCallError
        nil
      end

      def resolved_sampling
        LlmConfig::Sampling.resolve(@header.metadata)
      rescue ArgumentError, SystemCallError, IOError
        LlmConfig::Sampling::DEFAULTS
      end

      def ctx_store = Store.new(LlmConfig::MODEL_CTX_PATH)
      def sampling_store = Store.new(LlmConfig::MODEL_SAMPLING_PATH)
      def compute_store = Store.new(LlmConfig::MODEL_COMPUTE_PATH)
      def n_cpu_moe_store = Store.new(N_CPU_MOE_PATH)
      def packing_store = Store.new(TERNARY_PACKING_PATH)
      def mmproj_store = Store.new(LlmConfig::MODEL_MMPROJ_PATH)
    end
  end
end
