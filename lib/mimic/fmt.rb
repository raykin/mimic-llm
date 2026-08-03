module Mimic
  module Fmt
    class << self
      # "180000" -> "180,000"
      def commas(n)
        n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
      end

      # Decimal GB (1000^3), the unit model files are advertised in.
      def human_size(bytes) = format("%.1f GB", bytes / 1000.0**3)
    end
  end
end
