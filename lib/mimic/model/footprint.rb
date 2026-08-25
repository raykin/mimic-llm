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
      # A sliding-window layer's cache does not grow with context: llama.cpp
      # sizes it at the window plus one ubatch, padded to 256 cells
      # (llama-kv-cache-iswa.cpp:73). Both engine presets set
      # --ubatch-size 1024, so that is what the window cache is priced at.
      SWA_UBATCH = 1024
      SWA_CELL_PAD = 256

      # The recurrent state is f32 whatever --cache-type-k/v says.
      RECURRENT_BPE = 4.0

      COMPUTE_FRACTION = 0.06
      COMPUTE_FLOOR_MIB = 1024
      COMPUTE_CEILING_MIB = 2048
      DESKTOP_RESERVE_MIB = 2048 # leave this much VRAM for the desktop/other apps

      def self.compute_default(total_mib)
        (total_mib * COMPUTE_FRACTION).round.clamp(COMPUTE_FLOOR_MIB, COMPUTE_CEILING_MIB)
      end

      def initialize(header, ctx:, cache_type:, weights_bytes:, compute_mib: nil, drafting: false, slots: 1,
                     reclaimable_mib: 0)
        @header = header
        @ctx = ctx
        @cache_type = cache_type
        @weights_bytes = weights_bytes
        @compute_mib = compute_mib
        @drafting = drafting
        @slots = slots
        @reclaimable_mib = reclaimable_mib
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
      # Window layers are the fixed half: they hold the same cells at ctx 4096
      # as at 262144, so only the full-attention layers scale.
      def kv_mib = kv_per_token_mib && kv_per_token_mib * @ctx + kv_fixed_mib
      def compute_mib = @compute_mib || (total_mib && self.class.compute_default(total_mib))

      # A drafting engine builds a second context over the nextn block: its
      # own KV for those layers plus a compute buffer the same size as the
      # target's, since it runs the same graph shape at the same ubatch.
      # Measured on Qwen3.6-35B-A3B at ctx 163840 (2026-08-23): 170 MiB KV
      # and a second 978 MiB CUDA0 compute buffer beside the target's 978.
      def draft_mib
        return 0 unless @drafting && kv_per_token_mib

        layers = target_attention_layers
        return compute_mib if layers.nil? || layers.zero?

        ((kv_per_token_mib * @ctx) / layers * @header.nextn_layers) + compute_mib
      end
      # What is actually available: the driver's free figure when it answers,
      # since the desktop's draw is measurable and moves. DESKTOP_RESERVE_MIB
      # is the fallback for a host where nvidia-smi cannot be read.
      #
      # `reclaimable_mib` is VRAM held by a server this launch replaces, which
      # the free figure counts as unavailable even though it is about to be
      # released. Other processes' VRAM stays subtracted -- only our own
      # outgoing server comes back. The fallback path has no free figure to
      # add to: the reserve is already the whole allowance.
      def budget_mib
        return @budget_mib if defined?(@budget_mib)

        free = Util::Host.gpu_free_mib
        @budget_mib = free ? free + @reclaimable_mib : (total_mib && total_mib - DESKTOP_RESERVE_MIB)
      end

      def need_mib
        return nil unless measurable?

        weights_mib + kv_mib + compute_mib + draft_mib
      end

      def fits? = measurable? && need_mib <= budget_mib

      # What is left of the budget once this configuration is resident.
      def headroom_mib = measurable? ? budget_mib - need_mib : nil

      # The longest context the card can hold at this cache type, weights and
      # compute buffer.
      def max_ctx
        return nil unless measurable?
        return 0 if kv_per_token_mib.zero?

        [0, ((budget_mib - weights_mib - compute_mib - draft_mib - kv_fixed_mib) / kv_per_token_mib).to_i].max
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

      # The attention-layer count kv_mib was built from, so draft_mib can
      # price one nextn block as a fraction of it.
      def target_attention_layers
        meta = @header.metadata
        arch = meta["general.architecture"]
        arch && attention_layers(meta, arch)
      end

      def kv_per_token_mib = kv_shape && mib(kv_shape.first)
      def kv_fixed_mib = kv_shape ? mib(kv_shape.last) + recurrent_mib : 0

      def mib(elems) = elems * CACHE_BPE.fetch(@cache_type, 2.0) / 1024 / 1024

      # [elements per token, elements held whatever the context is]. Layers
      # are walked one at a time because a model can mix widths: gemma-4
      # gives its window layers 16 KV heads at head dim 256 and its
      # full-attention layers 4 at 512, in a repeating pattern the header
      # spells out per layer.
      def kv_shape
        return @kv_shape if defined?(@kv_shape)

        @kv_shape = read_kv_shape
      end

      def read_kv_shape
        meta = @header.metadata
        arch = meta["general.architecture"]
        return nil unless arch

        n_layer = attention_layers(meta, arch)
        k_dim = meta["#{arch}.attention.key_length"] || derived_head_dim(meta, arch)
        # K and V are not always the same width -- gemma-4 ships both keys
        # separately, and reading only key_length silently prices V wrong.
        v_dim = meta["#{arch}.attention.value_length"] || k_dim
        heads = heads_kv(meta, arch)
        return nil unless n_layer && heads && k_dim && v_dim

        swa = swa_pattern(meta, arch)
        swa_dims = (meta["#{arch}.attention.key_length_swa"] || k_dim) +
                   (meta["#{arch}.attention.value_length_swa"] || v_dim)
        cells = swa_cells(meta, arch)
        per_token = 0
        fixed = 0
        cached_layers(meta, arch, n_layer).times do |il|
          n_kv = heads.is_a?(Array) ? heads[il] : heads
          next if n_kv.nil?

          if swa[il]
            fixed += n_kv * swa_dims * cells
          else
            per_token += n_kv * (k_dim + v_dim)
          end
        end
        [per_token, fixed]
      end

      # Per layer in the newer headers, one number in the older ones. Absent
      # means multi-head attention: llama.cpp defaults it to head_count
      # (llama-model.cpp:1186).
      def heads_kv(meta, arch)
        meta["#{arch}.attention.head_count_kv"] || meta["#{arch}.attention.head_count"]
      end

      # Only the explicit per-layer pattern is honoured. Architectures whose
      # window layout is a rule in llama.cpp rather than a key in the file
      # (gemma-3's set_swa_pattern) read as all-full-attention here, which
      # over-states their KV rather than inventing a layout.
      def swa_pattern(meta, arch)
        pattern = meta["#{arch}.attention.sliding_window_pattern"]
        pattern.is_a?(Array) ? pattern.map { |flag| !flag.zero? } : []
      end

      def swa_cells(meta, arch)
        window = meta["#{arch}.attention.sliding_window"].to_i
        cells = [@ctx, window * @slots + SWA_UBATCH].min
        -(-cells / SWA_CELL_PAD) * SWA_CELL_PAD
      end

      # Layers past this reuse an earlier layer's cache instead of holding
      # their own (llama-model.cpp:2357). shared_kv_layers is how many of the
      # stack does so.
      def cached_layers(meta, arch, n_layer)
        n_layer - meta["#{arch}.attention.shared_kv_layers"].to_i
      end

      # Hybrid attention (Qwen3.5/Next-style): only every Nth layer keeps a
      # standard KV cache that scales with context -- the rest are
      # linear/recurrent-attention layers with a small fixed-size state.
      # block_count includes the MTP draft heads, which are not part of the
      # target's layer stack -- counting them here inflates the KV estimate by
      # a whole attention layer on any MTP-capable GGUF. draft_mib adds them
      # back when the engine is drafting.
      def attention_layers(meta, arch)
        n_layer = meta["#{arch}.block_count"]
        interval = meta["#{arch}.full_attention_interval"]
        return n_layer unless n_layer && interval

        -(-(n_layer - @header.nextn_layers) / interval) # ceil div
      end

      # A hybrid model's linear-attention layers hold an f32 recurrent state
      # instead of a K/V pair. It never scales with context but it is real
      # VRAM, and neither engine reports it as KV: ik folds it into the KV
      # buffer while printing only K and V in `KV self size`, and llama.cpp
      # allocates it as a separate recurrent buffer. Verified against ik on
      # Qwen3.6-35B-A3B (62.81 MiB over 30 layers) and Qwen3.8-27B
      # (149.63 over 48).
      def recurrent_mib
        meta = @header.metadata
        arch = meta["general.architecture"]
        state = recurrent_state_elems(meta, arch)
        return 0 if state.zero?

        layers = recurrent_layers(meta, arch)
        layers * state * @slots * RECURRENT_BPE / 1024 / 1024
      end

      # The layers that are not full-attention ones: llama.cpp marks every
      # layer whose 1-based index is not a multiple of the interval
      # (llama-hparams.cpp:603), and the nextn heads are never recurrent.
      def recurrent_layers(meta, arch)
        n_layer = meta["#{arch}.block_count"]
        return 0 unless n_layer && meta["#{arch}.full_attention_interval"]

        (n_layer - @header.nextn_layers) - attention_layers(meta, arch)
      end

      # The gated-delta-net state: a convolution window over 2 key groups plus
      # the value stream, and one square matrix per value head
      # (llama-hparams.h:329). Only this layout is priced -- a plain Mamba
      # state lands in the K/V caches instead and is already counted there.
      def recurrent_state_elems(meta, arch)
        groups = meta["#{arch}.ssm.group_count"].to_i
        inner = meta["#{arch}.ssm.inner_size"].to_i
        heads = meta["#{arch}.ssm.time_step_rank"].to_i
        return 0 if groups.zero? || inner.zero? || heads.zero?

        key_dim = meta["#{arch}.ssm.state_size"].to_i * groups
        conv = [meta["#{arch}.ssm.conv_kernel"].to_i - 1, 0].max
        head_dim = inner / heads
        conv * (2 * key_dim + inner) + head_dim * head_dim * heads
      end

      def derived_head_dim(meta, arch)
        emb = meta["#{arch}.embedding_length"]
        n_head = meta["#{arch}.attention.head_count"]
        emb && n_head && !n_head.zero? ? emb / n_head : nil
      end
    end
  end
end
