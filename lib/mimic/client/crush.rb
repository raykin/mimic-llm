require_relative "base"

module Mimic
  module Client
    class Crush < Base
      CONFIG_PATH = Pathname.new(Dir.home) / ".config/crush/crush.json"

      def sync
        data = load_json
        return false if data.nil?

        provider = data.dig("providers", PROVIDER)
        return false if provider.nil?

        models = (provider["models"] ||= [])
        entry = models.find { |model| model["id"] == model_alias }
        if entry.nil?
          entry = { "id" => model_alias, "name" => model_alias }
          models.unshift(entry)
        end
        entry["context_window"] = ctx
        entry["default_max_tokens"] = MAX_TOKENS
        write_json(config_path, data)
        true
      end
    end
  end
end
