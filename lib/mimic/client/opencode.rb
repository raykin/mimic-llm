require_relative "base"

module Mimic
  module Client
    class Opencode < Base
      CONFIG_PATH = Pathname.new(Dir.home) / ".config/opencode/opencode.jsonc"

      def sync
        data = load_json
        return false if data.nil?

        if commented?(config_path)
          warn "[opencode] #{config_path} contains comments; skipping write so they are not lost"
          return false
        end

        provider = data.dig("provider", PROVIDER)
        return false if provider.nil?

        models = (provider["models"] ||= {})
        entry = (models[model_alias] ||= { "name" => model_alias })
        entry["limit"] = { "context" => ctx, "output" => MAX_TOKENS }
        data["model"] = "#{PROVIDER}/#{model_alias}"
        write_json(config_path, data)
        true
      end
    end
  end
end
