require "psych"
require "date"
require_relative "base"

module Mimic
  module Client
    # Unlike the others, goose has no hand-made llamacpp block to find:
    # providers live in their own file under custom_providers/, so this writes
    # one. The config dir existing is what stands in for "goose is installed".
    class Goose < Base
      CONFIG_PATH = Pathname.new(Dir.home) / ".config/goose/config.yaml"
      PROVIDER_FILE = Pathname.new(Dir.home) / ".config/goose/custom_providers/llamacpp.json"

      def sync
        return false unless config_path.file?

        write_provider_file
        data = load_yaml
        return false if data.nil?

        data["GOOSE_PROVIDER"] = PROVIDER
        data["GOOSE_MODEL"] = model_alias
        data["active_provider"] = PROVIDER
        (data["providers"] ||= {})[PROVIDER] = { "enabled" => true, "model" => model_alias, "configured" => true }
        config_path.write(Psych.dump(data))
        true
      end

      private

      def write_provider_file
        self.class::PROVIDER_FILE.dirname.mkpath
        write_json(self.class::PROVIDER_FILE, {
                     "name" => PROVIDER,
                     "engine" => "openai",
                     "display_name" => "llama.cpp (local)",
                     "description" => "Local llama-server, OpenAI-compatible",
                     "base_url" => "#{base_url}/v1/chat/completions",
                     "models" => [{ "name" => model_alias, "context_limit" => ctx }],
                     "supports_streaming" => true,
                     "requires_auth" => false,
                   })
      end

      def load_yaml
        Psych.safe_load(config_path.read, permitted_classes: [Symbol, Date, Time], aliases: true) || {}
      rescue SystemCallError, Psych::Exception
        nil
      end
    end
  end
end
