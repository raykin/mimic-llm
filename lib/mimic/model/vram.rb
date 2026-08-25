require "open3"
require_relative "schema"
require_relative "../model"

# VRAM preflight -- estimate weights + KV footprint from a GGUF header and
# compare against the GPU budget, so setup can reject a context length that
# would load but crash at runtime once the KV cache fills (llama.cpp
# over-commits ctx).
module Mimic
  class Model
    module Vram
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

      class << self
        def compute_default(total_mib)
          (total_mib * COMPUTE_FRACTION).round.clamp(COMPUTE_FLOOR_MIB, COMPUTE_CEILING_MIB)
        end

        def kv_elems_per_token(meta)
          arch = meta["general.architecture"]
          return nil unless arch

          n_layer = attention_layers(meta, arch)
          n_kv = meta["#{arch}.attention.head_count_kv"]
          head_dim = meta["#{arch}.attention.key_length"] || derived_head_dim(meta, arch)
          return nil unless n_layer && n_kv && head_dim

          n_layer * n_kv * head_dim * 2 # K + V elements per token
        end

        # What a loaded instance holds beyond the weights + KV estimate, in
        # MiB, or nil when it can't be measured. The residual is what
        # compute_default stands in for, so it is worth storing under the exact ctx
        # and cache type it was taken at.
        def measured_overhead_mib(model_path, ctx, cache_type, pids:)
          est = Model.new(model_path).preflight(ctx, cache_type, compute_mib: 0)
          used = gpu_process_mib(pids)
          return nil if est.nil? || used.nil?

          overhead = used - est[:need_mib]
          overhead.positive? ? overhead.round : nil
        end

        # How many layers' experts have to move to CPU to cover a VRAM
        # deficit. 0 when nothing needs moving, nil when the model is dense
        # (nothing to move) or the ceiling can't cover the gap.
        def layers_to_offload(model_path, deficit_mib:, ceiling:)
          return 0 if deficit_mib <= 0

          per_layer = Schema.expert_bytes_per_layer(model_path)
          return nil if per_layer.nil? || per_layer.zero?

          layers = (deficit_mib / (per_layer / 1024.0 / 1024.0)).ceil
          layers <= ceiling ? layers : nil
        end

        def gpu_total_mib
          out, status = Open3.capture2("nvidia-smi", "--query-gpu=memory.total", "--format=csv,noheader,nounits")
          return nil unless status.success?

          Integer(out.lines.first.to_s.strip)
        rescue Errno::ENOENT, ArgumentError, TypeError
          nil
        end

        private

        # VRAM held by the given processes. The engine that owns the CUDA
        # context is not always the process we spawned -- llama.cpp's router
        # loads each model in a child -- so the caller passes the whole
        # descendant set and every match counts.
        def gpu_process_mib(pids)
          out, status = Open3.capture2("nvidia-smi", "--query-compute-apps=pid,used_memory",
                                       "--format=csv,noheader,nounits")
          return nil unless status.success?

          wanted = pids.map(&:to_i)
          total = out.lines.filter_map do |line|
            pid, mib = line.split(",").map { |field| field.strip.to_i }
            mib if wanted.include?(pid)
          end.sum
          total.positive? ? total : nil
        rescue Errno::ENOENT, ArgumentError, TypeError
          nil
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
end
