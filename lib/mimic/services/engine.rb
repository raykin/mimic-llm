require_relative "llama"
require_relative "ik_llama"

module Mimic
  module Services
    module Engine
      def self.for(settings)
        settings.ik? ? IkLlama.new(settings) : Llama.new(settings)
      end
    end
  end
end
