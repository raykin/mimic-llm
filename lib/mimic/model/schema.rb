# GGUF header reader -- the key/value metadata block at the head of a model
# file. Tensor data is never touched; every question here is answered from
# the first few hundred KB.
module Mimic
  class Model
    module Schema
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

      EXPERT_TENSOR = /\Ablk\.(\d+)\..*exps/

      # Ternary (Bonsai) weights. ggml type 42 is the trap: mainline llama.cpp
      # packs 64 weights into an 18-byte block, PrismML's fork 128 into 34, and
      # neither reads the other's file -- under the same type id, so only the
      # measured bytes-per-weight tells them apart. Ids above what any engine
      # here defines (Prism's original 142) are readable by none of them.
      TERNARY_TYPE = 42
      MAX_KNOWN_TYPE = 42
      G128_BYTES_PER_WEIGHT = 34 / 128.0
      G64_BYTES_PER_WEIGHT = 18 / 64.0

      # Architectures that only ever ship as encoders. A decoder-shaped
      # embedding model (Qwen3-Embedding and friends) keeps its chat
      # architecture and is caught by the pooling/causal keys instead.
      ENCODER_ARCHS = %w[bert nomic-bert nomic-bert-moe jina-bert-v2 modern-bert neo-bert xlm-roberta t5encoder].freeze
      POOLING_RANK = 4

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

        def moe?(path, meta: nil)
          arch_value(path, meta) { |m, arch| !m.fetch("#{arch}.expert_count", 0).zero? }
        end

        def embedding?(path, meta: nil)
          arch_value(path, meta) do |m, arch|
            m["#{arch}.attention.causal"] == 0 ||
              m.key?("#{arch}.pooling_type") ||
              ENCODER_ARCHS.include?(arch)
          end
        end

        def pooling_type(path, meta: nil)
          arch_value(path, meta) { |m, arch| m["#{arch}.pooling_type"] }
        end

        def block_count(path, meta: nil)
          arch_value(path, meta) { |m, arch| m["#{arch}.block_count"] }
        end

        # Average bytes of expert weights per MoE layer -- what moving one
        # layer's experts to CPU with --n-cpu-moe frees on the GPU. nil for a
        # dense model or an unreadable file.
        #
        # Sizes come from the gaps between consecutive tensor offsets rather
        # than from shape x type, which would need the whole ggml block-size
        # table to be correct for every quant.
        # Which engine's ternary packing this model carries: :g128 (PrismML
        # fork), :g64 (mainline llama.cpp), :unsupported (a private type no
        # engine here defines), or nil when the model is not ternary.
        def ternary_packing(path)
          tensors, data_start = tensor_offsets(path)
          return nil if tensors.nil? || tensors.empty?
          return :unsupported if tensors.any? { |t| t[:type] > MAX_KNOWN_TYPE }

          sizes = tensor_sizes(tensors, File.size(path) - data_start)
          ternary = tensors.select { |t| t[:type] == TERNARY_TYPE }
          return nil if ternary.empty?

          # The gap to the next tensor includes GGUF's alignment padding, so
          # the biggest tensor is the one whose bytes-per-weight is least
          # distorted by it.
          widest = ternary.max_by { |t| sizes.fetch(t[:name]) }
          per_weight = sizes.fetch(widest[:name]).to_f / widest[:elements]
          (per_weight - G128_BYTES_PER_WEIGHT).abs < (per_weight - G64_BYTES_PER_WEIGHT).abs ? :g128 : :g64
        end

        def expert_bytes_per_layer(path)
          tensors, data_start = tensor_offsets(path)
          return nil if tensors.nil? || tensors.empty?

          sizes = tensor_sizes(tensors, File.size(path) - data_start)
          experts = sizes.select { |name, _| name.match?(EXPERT_TENSOR) }
          return nil if experts.empty?

          layers = experts.keys.map { |name| name[EXPERT_TENSOR, 1] }.uniq.size
          experts.values.sum / layers
        end

        private

        # [[name, data offset], ...] from the tensor info block that follows
        # the KV block. The KV walk has to be exhaustive here -- the early stop
        # read_metadata takes on a vocab-sized array would leave the file
        # positioned mid-header.
        def tensor_offsets(path)
          File.open(path, "rb") do |f|
            return nil unless f.read(4) == MAGIC

            u32(f)
            n_tensors = u64(f)
            u64(f).times { read_str(f); skip_value(f, u32(f)) }
            tensors = Array.new(n_tensors) do
              name = read_str(f)
              elements = Array.new(u32(f)) { u64(f) }.inject(1, :*)
              { name: name, elements: elements, type: u32(f), offset: u64(f) }
            end
            [tensors, f.pos]
          end
        rescue Errno::ENOENT, ArgumentError, EOFError, NoMethodError
          nil
        end

        # Tensor offsets are relative to the start of the data block, so the
        # last tensor is bounded by the tail of the file rather than by a
        # following offset.
        def tensor_sizes(tensors, data_bytes)
          ordered = tensors.sort_by { |t| t[:offset] }
          ordered.each_with_index.to_h do |tensor, i|
            following = ordered[i + 1]
            [tensor[:name], (following ? following[:offset] : data_bytes) - tensor[:offset]]
          end
        end

        def arch_value(path, meta = nil)
          meta ||= read_metadata(path)
          arch = meta["general.architecture"]
          arch && yield(meta, arch)
        rescue Errno::ENOENT, ArgumentError, EOFError
          nil
        end

        def u32(f) = f.read(4).unpack1("L<")
        def u64(f) = f.read(8).unpack1("Q<")
        def read_str(f) = f.read(u64(f)).force_encoding("UTF-8").scrub

        def read_scalar(f, vtype)
          f.read(SCALAR_SIZE.fetch(vtype)).unpack1(SCALAR_FMT.fetch(vtype))
        end

        def arch_block_read?(meta)
          arch = meta["general.architecture"]
          !arch.nil? && meta.keys.any? { |k| k.start_with?("#{arch}.") }
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
end
