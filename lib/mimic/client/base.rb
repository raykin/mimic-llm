require "json"
require "pathname"

module Mimic
  module Client
    # One SWE agent that reads the LLM config. Each subclass owns its config
    # path and the shape that file wants; `sync` answers whether it wrote.
    class Base
      PROVIDER = "llamacpp".freeze
      MAX_TOKENS = 8192

      def initialize(settings)
        @settings = settings
      end

      def name = self.class.name.split("::").last.downcase
      def config_path = self.class::CONFIG_PATH
      def sync = raise(NotImplementedError)

      private

      def model_alias = @settings.model.name
      def ctx = @settings.model.context_length
      def base_url = @settings.llama.base_url

      def load_json(path = config_path)
        text = path.read.gsub(%r{^\s*//.*$}, "")
        JSON.parse(text)
      rescue SystemCallError, JSON::ParserError
        nil
      end

      def write_json(path, data)
        path.write("#{JSON.pretty_generate(data)}\n")
      end

      def commented?(path)
        path.read.match?(%r{^\s*//})
      rescue SystemCallError
        false
      end
    end
  end
end
