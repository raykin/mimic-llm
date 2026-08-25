module Mimic
  class Model
    # GGUF header reader -- the key/value metadata block and the tensor info
    # block at the head of a model file. Tensor data is never touched; every
    # question here is answered from the first few hundred KB.
    #
    # Raises for a file that is missing, truncated or not a GGUF at all;
    # Model::Header is what turns those into nil.
    class Gguf
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

      def initialize(path)
        @path = path.to_s
        @metadata = {}
      end

      # Scalar + string KV pairs. Arrays (vocab/merges) are skipped.
      def metadata(full: false)
        @metadata[full] ||= read_metadata(full: full)
      end

      # [{name:, elements:, type:, offset:}, ...] from the tensor info block
      # that follows the KV block.
      def tensors
        return @tensors if defined?(@tensors)

        @tensors, @data_start = read_tensors
        @tensors
      end

      # {name => bytes}. Offsets are relative to the start of the data block,
      # so the last tensor is bounded by the tail of the file rather than by a
      # following offset.
      def tensor_sizes
        @tensor_sizes ||= sizes_from_gaps(tensors, File.size(@path) - @data_start)
      end

      private

      def read_metadata(full:)
        meta = {}
        truncated = false
        File.open(@path, "rb") do |f|
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

        read_metadata(full: true)
      end

      # The KV walk has to be exhaustive here -- the early stop metadata takes
      # on a vocab-sized array would leave the file positioned mid-header.
      def read_tensors
        File.open(@path, "rb") do |f|
          raise ArgumentError, "not a GGUF file" unless f.read(4) == MAGIC

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
      end

      def sizes_from_gaps(tensors, data_bytes)
        ordered = tensors.sort_by { |tensor| tensor[:offset] }
        ordered.each_with_index.to_h do |tensor, i|
          following = ordered[i + 1]
          [tensor[:name], (following ? following[:offset] : data_bytes) - tensor[:offset]]
        end
      end

      def u32(f) = read_exactly(f, 4).unpack1("L<")
      def u64(f) = read_exactly(f, 8).unpack1("Q<")
      def read_str(f) = read_exactly(f, u64(f)).force_encoding("UTF-8").scrub

      def read_scalar(f, vtype)
        read_exactly(f, SCALAR_SIZE.fetch(vtype)).unpack1(SCALAR_FMT.fetch(vtype))
      end

      # A header cut mid-value leaves IO#read returning short or nil, which
      # would surface as NoMethodError on the unpack that follows.
      def read_exactly(f, bytes)
        chunk = f.read(bytes)
        raise EOFError, "truncated gguf header" if chunk.nil? || chunk.bytesize < bytes

        chunk
      end

      def arch_block_read?(meta)
        arch = meta["general.architecture"]
        !arch.nil? && meta.keys.any? { |key| key.start_with?("#{arch}.") }
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
          len = buf.unpack1("Q<", offset: off)
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
      # is off -- the parse stops there.
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
