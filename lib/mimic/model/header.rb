require_relative "schema"

module Mimic
  class Model
    class Header
      def initialize(path)
        @path = path.to_s
      end

      def moe? = Schema.moe?(@path, meta: metadata)
      def embedding? = Schema.embedding?(@path, meta: metadata)
      def pooling_type = Schema.pooling_type(@path, meta: metadata)
      def block_count = Schema.block_count(@path, meta: metadata)

      def ternary_packing
        return @ternary_packing if defined?(@ternary_packing)

        @ternary_packing = Schema.ternary_packing(@path)
      end

      def expert_bytes_per_layer
        return @expert_bytes_per_layer if defined?(@expert_bytes_per_layer)

        @expert_bytes_per_layer = Schema.expert_bytes_per_layer(@path)
      end

      def metadata(full: false)
        @metadata ||= {}
        @metadata[full] ||= Schema.read_metadata(@path, full: full)
      rescue Errno::ENOENT, ArgumentError, EOFError
        @metadata[full] = {}
      end
    end
  end
end
