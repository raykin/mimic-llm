require "open3"

# VRAM preflight -- estimate weights + KV footprint from a GGUF header and
# compare against the GPU budget, so setup can reject a context length that
# would load but crash at runtime once the KV cache fills (llama.cpp
# over-commits ctx).
module Mimic
  module Vram
    MAGIC = "GGUF"
    SCALAR_SIZE = { 0 => 1, 1 => 1, 2 => 2, 3 => 2, 4 => 4, 5 => 4, 6 => 4, 7 => 1, 10 => 8, 11 => 8, 12 => 8 }.freeze
    SCALAR_FMT = {
      0 => "C", 1 => "c", 2 => "S<", 3 => "s<", 4 => "L<", 5 => "l<",
      6 => "e", 7 => "C", 10 => "Q<", 11 => "q<", 12 => "E",
    }.freeze
    STRING = 8
    ARRAY = 9

    # A string array this long is a vocab/merges table: megabytes of
    # length-prefixed entries that can only be walked one at a time. No caller
    # needs them, so the parse stops there and restarts in full only if the
    # architecture block turned out to sit behind them.
    BIG_STRING_ARRAY = 4096
    CHUNK = 1 << 20

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

    COMPUTE_MIB = 2048 # graph/compute buffer headroom (incl. MTP draft buffer slack)
    DESKTOP_RESERVE_MIB = 1024 # leave this much VRAM for the desktop/other apps

    class << self
      # Scalar + string KV pairs from a GGUF header. Arrays (vocab/merges) are skipped.
      def read_metadata(path, full: false)
        meta = {}
        truncated = false
        File.open(path, "rb") do |f|
          raise ArgumentError, "not a GGUF file" unless f.read(4) == MAGIC

          u32(f) # version (v2/v3 both use u64 counts below)
          u64(f) # tensor count
          u64(f).times do
            key = read_str(f)
            vtype = u32(f)
            if SCALAR_FMT.key?(vtype)
              meta[key] = read_scalar(f, vtype)
            elsif vtype == STRING
              meta[key] = read_str(f)
            elsif !skip_value(f, vtype, full: full)
              truncated = true
              break
            end
          end
        end
        return meta unless truncated && !arch_block_read?(meta)

        read_metadata(path, full: true)
      end

      # true/false if the GGUF header says MoE/dense, nil if unreadable.
      def moe?(path)
        meta = read_metadata(path)
        arch = meta["general.architecture"]
        return nil unless arch

        !meta.fetch("#{arch}.expert_count", 0).zero?
      rescue Errno::ENOENT, ArgumentError, EOFError
        nil
      end

      # Layer count for the model's architecture, nil if unreadable.
      def block_count(path)
        meta = read_metadata(path)
        arch = meta["general.architecture"]
        arch && meta["#{arch}.block_count"]
      rescue Errno::ENOENT, ArgumentError, EOFError
        nil
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

      # Return an estimate hash, or nil when it can't be computed (no GPU / parse fail).
      #
      # Keys: fits, need_mib, budget_mib, total_mib, weights_mib, kv_mib, max_ctx.
      def preflight(model_path, ctx, cache_type)
        elems = kv_elems_per_token(read_metadata(model_path))
        total = gpu_total_mib
        return nil if elems.nil? || total.nil?

        per_tok_mib = elems * CACHE_BPE.fetch(cache_type, 2.0) / 1024 / 1024
        weights_mib = File.size(model_path) / 1024.0 / 1024.0
        kv_mib = per_tok_mib * ctx
        need_mib = weights_mib + kv_mib + COMPUTE_MIB
        budget = total - DESKTOP_RESERVE_MIB
        max_ctx = per_tok_mib.zero? ? 0 : ((budget - weights_mib - COMPUTE_MIB) / per_tok_mib).to_i
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

      def u32(f) = f.read(4).unpack1("L<")
      def u64(f) = f.read(8).unpack1("Q<")
      def read_str(f) = f.read(u64(f)).force_encoding("UTF-8").scrub

      def read_scalar(f, vtype)
        f.read(SCALAR_SIZE.fetch(vtype)).unpack1(SCALAR_FMT.fetch(vtype))
      end

      def gpu_total_mib
        out, status = Open3.capture2("nvidia-smi", "--query-gpu=memory.total", "--format=csv,noheader,nounits")
        return nil unless status.success?

        Integer(out.lines.first.to_s.strip)
      rescue Errno::ENOENT, ArgumentError, TypeError
        nil
      end

      def arch_block_read?(meta)
        arch = meta["general.architecture"]
        !arch.nil? && meta.keys.any? { |k| k.start_with?("#{arch}.") }
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

      def skip_string_array(f, count)
        buf = "".b
        off = 0
        base = f.pos
        count.times do
          if buf.bytesize - off < 8
            base += off
            f.seek(base)
            buf = f.read(CHUNK) || "".b
            off = 0
            raise EOFError, "truncated gguf string array" if buf.bytesize < 8
          end
          len = buf.byteslice(off, 8).unpack1("Q<")
          off += 8
          if len > buf.bytesize - off
            base += off + len
            f.seek(base)
            buf = "".b
            off = 0
          else
            off += len
          end
        end
        f.seek(base + off)
      end

      # Returns false when the value was a vocab-sized string array and `full`
      # is off -- the caller stops parsing there.
      def skip_value(f, vtype, full: true)
        if SCALAR_SIZE.key?(vtype)
          f.seek(SCALAR_SIZE[vtype], IO::SEEK_CUR)
        elsif vtype == STRING
          f.seek(u64(f), IO::SEEK_CUR)
        elsif vtype == ARRAY
          elem_type = u32(f)
          count = u64(f)
          if SCALAR_SIZE.key?(elem_type)
            f.seek(SCALAR_SIZE[elem_type] * count, IO::SEEK_CUR)
          elsif elem_type == STRING
            return false if !full && count > BIG_STRING_ARRAY

            skip_string_array(f, count)
          else
            raise ArgumentError, "nested array type #{elem_type}"
          end
        else
          raise ArgumentError, "unknown gguf type #{vtype}"
        end
        true
      end
    end
  end
end
