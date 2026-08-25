require_relative "base"

module Mimic
  module Client
    class Pi < Base
      CONFIG_PATH = Pathname.new(Dir.home) / ".pi/agent/models.json"
      SETTINGS_PATH = Pathname.new(Dir.home) / ".pi/agent/settings.json"

      def sync
        data = load_json
        return false if data.nil?

        provider = data.dig("providers", PROVIDER)
        return false if provider.nil?

        models = (provider["models"] ||= [])
        entry = models.find { |model| model["id"] == model_alias }
        if entry.nil?
          entry = new_entry
          models.unshift(entry)
        end
        entry["contextWindow"] = ctx
        entry["maxTokens"] = MAX_TOKENS
        write_json(config_path, data)
        sync_settings
        true
      end

      private

      def new_entry
        {
          "id" => model_alias,
          "name" => "#{model_alias} (local llama.cpp)",
          "input" => ["text"],
          "cost" => { "input" => 0, "output" => 0, "cacheRead" => 0, "cacheWrite" => 0 },
        }
      end

      def sync_settings
        settings = load_json(self.class::SETTINGS_PATH)
        return if settings.nil?

        settings["defaultProvider"] = PROVIDER
        settings["defaultModel"] = model_alias
        write_json(self.class::SETTINGS_PATH, settings)
      end
    end
  end
end
