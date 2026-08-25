require "json"
require_relative "../llm_config"

module Mimic
  class Model
    # Shared read/merge/write over a sidecar JSON file keyed by resolved
    # model path. Value shape is the caller's business -- Store only owns the
    # file and the key resolution.
    class Store
      def initialize(path)
        @path = path
      end

      def fetch(model_path) = read[key(model_path)]

      def write(model_path, value)
        known = read
        known[key(model_path)] = value
        persist(known)
      end

      def delete(model_path)
        known = read
        return unless known.key?(key(model_path))

        known.delete(key(model_path))
        persist(known)
      end

      private

      def key(model_path) = LlmConfig.resolve_path(model_path)

      def read
        JSON.parse(@path.read)
      rescue SystemCallError, JSON::ParserError
        {}
      end

      def persist(known)
        @path.dirname.mkpath
        @path.write(JSON.pretty_generate(known))
      end
    end
  end
end
