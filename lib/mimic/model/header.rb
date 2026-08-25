require_relative "gguf"

module Mimic
  class Model
    # Questions about one GGUF's header. Everything is answered off a single
    # parse, and a file that is missing, truncated or not a GGUF answers nil
    # rather than raising -- callers ask about models found by a directory
    # scan, where an unreadable file is ordinary.
    class Header
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

      MTP_SCAN_BYTES = 8_000_000

      def initialize(path)
        @path = path.to_s
        @gguf = Gguf.new(@path)
      end

      def moe? = arch_value { |meta, arch| !meta.fetch("#{arch}.expert_count", 0).zero? }

      def embedding?
        arch_value do |meta, arch|
          meta["#{arch}.attention.causal"] == 0 ||
            meta.key?("#{arch}.pooling_type") ||
            ENCODER_ARCHS.include?(arch)
        end
      end

      # MTP-capable GGUFs carry a *.nextn_predict_layers key. Read as raw
      # bytes rather than through the parsed metadata: the key is
      # architecture-prefixed and a model whose header will not parse at all
      # still answers false instead of raising out of render_preset.
      def supports_mtp?
        File.open(@path, "rb") { |f| f.read(MTP_SCAN_BYTES).to_s.include?("nextn_predict_layers") }
      rescue SystemCallError, IOError
        false
      end

      def pooling_type = arch_value { |meta, arch| meta["#{arch}.pooling_type"] }
      def block_count = arch_value { |meta, arch| meta["#{arch}.block_count"] }

      # Which engine's ternary packing this model carries: :g128 (PrismML
      # fork), :g64 (mainline llama.cpp), :unsupported (a private type no
      # engine here defines), or nil when the model is not ternary.
      def ternary_packing
        return @ternary_packing if defined?(@ternary_packing)

        @ternary_packing = read_ternary_packing
      end

      # Average bytes of expert weights per MoE layer -- what moving one
      # layer's experts to CPU with --n-cpu-moe frees on the GPU. nil for a
      # dense model or an unreadable file.
      #
      # Sizes come from the gaps between consecutive tensor offsets rather
      # than from shape x type, which would need the whole ggml block-size
      # table to be correct for every quant.
      def expert_bytes_per_layer
        return @expert_bytes_per_layer if defined?(@expert_bytes_per_layer)

        @expert_bytes_per_layer = read_expert_bytes_per_layer
      end

      def metadata(full: false)
        @metadata ||= {}
        @metadata[full] ||= @gguf.metadata(full: full)
      rescue Errno::ENOENT, ArgumentError, EOFError
        @metadata[full] = {}
      end

      private

      def read_ternary_packing
        tensors = @gguf.tensors
        return nil if tensors.empty?
        return :unsupported if tensors.any? { |tensor| tensor[:type] > MAX_KNOWN_TYPE }

        ternary = tensors.select { |tensor| tensor[:type] == TERNARY_TYPE }
        return nil if ternary.empty?

        # The gap to the next tensor includes GGUF's alignment padding, so
        # the biggest tensor is the one whose bytes-per-weight is least
        # distorted by it.
        sizes = @gguf.tensor_sizes
        widest = ternary.max_by { |tensor| sizes.fetch(tensor[:name]) }
        per_weight = sizes.fetch(widest[:name]).to_f / widest[:elements]
        (per_weight - G128_BYTES_PER_WEIGHT).abs < (per_weight - G64_BYTES_PER_WEIGHT).abs ? :g128 : :g64
      rescue Errno::ENOENT, ArgumentError, EOFError
        nil
      end

      def read_expert_bytes_per_layer
        experts = @gguf.tensor_sizes.select { |name, _| name.match?(EXPERT_TENSOR) }
        return nil if experts.empty?

        layers = experts.keys.map { |name| name[EXPERT_TENSOR, 1] }.uniq.size
        experts.values.sum / layers
      rescue Errno::ENOENT, ArgumentError, EOFError
        nil
      end

      def arch_value
        arch = metadata["general.architecture"]
        arch && yield(metadata, arch)
      end
    end
  end
end
