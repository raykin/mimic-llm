require_relative "header"
require_relative "../util/host"

# What one model at one context costs on the GPU -- weights + KV + compute
# buffer against the card's budget, so setup can reject a context length that
# would load but crash at runtime once the KV cache fills (llama.cpp
# over-commits ctx).
module Mimic
  class Model
    class Footprint
      # bytes per element for KV cache quant types (block_bytes / block_elems)
      CACHE_BPE = {
        "f32" => 4.0,
        "f16" => 2.0,
        "bf16" => 2.0,
        "q8_0" => 34 / 32.0,
        "q5_1" => 24 / 32.0,
        "q5_0" => 22 / 32.0,
        "q4_1" => 20 / 32.0,
        "q4_0" => 18 / 32.0,
      }.freeze

      # The compute buffer tracks ubatch, vocab and graph shape -- not card
      # size -- so these are a guard, not a model. They scale with the card
      # because a fixed 2 GiB is 8% of a 3090 but 17% of a 12 GiB 3060, and a
      # smaller card runs the smaller ubatch/ctx that make the real buffer
      # smaller anyway. ComputeStore replaces the guess after the first launch.
      COMPUTE_FRACTION = 0.06
      COMPUTE_FLOOR_MIB = 1024
      COMPUTE_CEILING_MIB = 2048
      DESKTOP_RESERVE_MIB = 2048 # leave this much VRAM for the desktop/other apps

      def self.compute_default(total_mib)
        (total_mib * COMPUTE_FRACTION).round.clamp(COMPUTE_FLOOR_MIB, COMPUTE_CEILING_MIB)
      end

      def initialize(header, ctx:, cache_type:, weights_bytes:, compute_mib: nil)
        @header = header
        @ctx = ctx
        @cache_type = cache_type
        @weights_bytes = weights_bytes
        @compute_mib = compute_mib
      end

      # False when the header carries no KV shape or no GPU answers -- every
      # reader below is nil then, and callers print nothing rather than a
      # number they made up.
      def measurable? = !kv_per_token_mib.nil? && !total_mib.nil? && !@weights_bytes.nil?

      def total_mib
        return @total_mib if defined?(@total_mib)

        @total_mib = Util::Host.gpu_total_mib
      end

      def weights_mib = @weights_bytes && @weights_bytes / 1024.0 / 1024.0
      def kv_mib = kv_per_token_mib && kv_per_token_mib * @ctx
      def compute_mib = @compute_mib || (total_mib && self.class.compute_default(total_mib))
      def budget_mib = total_mib && total_mib - DESKTOP_RESERVE_MIB

      def need_mib
        return nil unless measurable?

        weights_mib + kv_mib + compute_mib
      end

      def fits? = measurable? && need_mib <= budget_mib

      # The longest context the card can hold at this cache type, weights and
      # compute buffer.
      def max_ctx
        return nil unless measurable?
        return 0 if kv_per_token_mib.zero?

        [0, ((budget_mib - weights_mib - compute_mib) / kv_per_token_mib).to_i].max
      end

      # How many layers' experts have to move to CPU to cover the deficit.
      # 0 when nothing needs moving, nil when the model is dense (nothing to
      # move) or the ceiling can't cover the gap.
      def layers_to_offload(ceiling:)
        return nil unless measurable?
        return 0 if need_mib <= budget_mib

        per_layer = @header.expert_bytes_per_layer
        return nil if per_layer.nil? || per_layer.zero?

        layers = ((need_mib - budget_mib) / (per_layer / 1024.0 / 1024.0)).ceil
        layers <= ceiling ? layers : nil
      end

      # What a loaded instance holds beyond this estimate, in MiB, or nil when
      # it can't be measured. The residual is what compute_default stands in
      # for, so it is worth storing under the exact ctx and cache type it was
      # taken at.
      def measured_overhead_mib(pids:)
        used = Util::Host.gpu_process_mib(pids)
        return nil if !measurable? || used.nil?

        overhead = used - need_mib
        overhead.positive? ? overhead.round : nil
      end

      private

      def kv_per_token_mib
        return @kv_per_token_mib if defined?(@kv_per_token_mib)

        elems = kv_elems_per_token
        @kv_per_token_mib = elems && elems * CACHE_BPE.fetch(@cache_type, 2.0) / 1024 / 1024
      end

      def kv_elems_per_token
        meta = @header.metadata
        arch = meta["general.architecture"]
        return nil unless arch

        n_layer = attention_layers(meta, arch)
        n_kv = meta["#{arch}.attention.head_count_kv"]
        head_dim = meta["#{arch}.attention.key_length"] || derived_head_dim(meta, arch)
        return nil unless n_layer && n_kv && head_dim

        n_layer * n_kv * head_dim * 2 # K + V elements per token
      end

      # Hybrid attention (Qwen3.5/Next-style): only every Nth layer keeps a
      # standard KV cache that scales with context -- the rest are
      # linear/recurrent-attention layers with a small fixed-size state.
      def attention_layers(meta, arch)
        n_layer = meta["#{arch}.block_count"]
        interval = meta["#{arch}.full_attention_interval"]
        return n_layer unless n_layer && interval

        -(-n_layer / interval) # ceil div
      end

      def derived_head_dim(meta, arch)
        emb = meta["#{arch}.embedding_length"]
        n_head = meta["#{arch}.attention.head_count"]
        emb && n_head && !n_head.zero? ? emb / n_head : nil
      end
    end
  end
end
