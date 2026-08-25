require "json"
require "psych"
require "date"
require "pathname"

module Mimic
  module Clients
    CRUSH_CONFIG = Pathname.new(Dir.home) / ".config/crush/crush.json"
    OPENCODE_CONFIG = Pathname.new(Dir.home) / ".config/opencode/opencode.jsonc"
    PI_MODELS = Pathname.new(Dir.home) / ".pi/agent/models.json"
    PI_SETTINGS = Pathname.new(Dir.home) / ".pi/agent/settings.json"
    GOOSE_CONFIG = Pathname.new(Dir.home) / ".config/goose/config.yaml"
    GOOSE_PROVIDER_FILE = Pathname.new(Dir.home) / ".config/goose/custom_providers/llamacpp.json"

    PROVIDER = "llamacpp"
    MAX_TOKENS = 8192

    # Every agent that reads the LLM config, in sync order. Single source
    # for both the sync loop and the `llm sync` help text, so the two
    # cannot drift apart.
    CLIENTS = %w[hermes goose crush opencode pi].freeze

    class << self
      def sync_crush(model_alias, ctx)
        data = load_json(CRUSH_CONFIG)
        return false if data.nil?

        provider = data.dig("providers", "llamacpp")
        return false if provider.nil?

        models = (provider["models"] ||= [])
        entry = models.find { |m| m["id"] == model_alias }
        if entry.nil?
          entry = { "id" => model_alias, "name" => model_alias }
          models.unshift(entry)
        end
        entry["context_window"] = ctx
        entry["default_max_tokens"] = MAX_TOKENS
        write_json(CRUSH_CONFIG, data)
        true
      end

      def sync_opencode(model_alias, ctx)
        data = load_json(OPENCODE_CONFIG)
        return false if data.nil?

        if commented?(OPENCODE_CONFIG)
          warn "[opencode] #{OPENCODE_CONFIG} contains comments; skipping write so they are not lost"
          return false
        end

        provider = data.dig("provider", "llamacpp")
        return false if provider.nil?

        models = (provider["models"] ||= {})
        entry = (models[model_alias] ||= { "name" => model_alias })
        entry["limit"] = { "context" => ctx, "output" => MAX_TOKENS }
        data["model"] = "llamacpp/#{model_alias}"
        write_json(OPENCODE_CONFIG, data)
        true
      end

      def sync_pi(model_alias, ctx)
        data = load_json(PI_MODELS)
        return false if data.nil?

        provider = data.dig("providers", "llamacpp")
        return false if provider.nil?

        models = (provider["models"] ||= [])
        entry = models.find { |m| m["id"] == model_alias }
        if entry.nil?
          entry = {
            "id" => model_alias,
            "name" => "#{model_alias} (local llama.cpp)",
            "input" => ["text"],
            "cost" => { "input" => 0, "output" => 0, "cacheRead" => 0, "cacheWrite" => 0 },
          }
          models.unshift(entry)
        end
        entry["contextWindow"] = ctx
        entry["maxTokens"] = MAX_TOKENS
        write_json(PI_MODELS, data)

        settings = load_json(PI_SETTINGS)
        unless settings.nil?
          settings["defaultProvider"] = "llamacpp"
          settings["defaultModel"] = model_alias
          write_json(PI_SETTINGS, settings)
        end
        true
      end

      # Point goose at llama-server via a custom OpenAI-compatible provider.
      #
      # Unlike the others, goose has no hand-made llamacpp block to find:
      # providers live in their own file under custom_providers/, so this
      # writes one. The config dir existing is what stands in for "goose is
      # installed".
      def sync_goose(model_alias, ctx, base_url)
        return false unless GOOSE_CONFIG.file?

        GOOSE_PROVIDER_FILE.dirname.mkpath
        write_json(GOOSE_PROVIDER_FILE, {
                     "name" => PROVIDER,
                     "engine" => "openai",
                     "display_name" => "llama.cpp (local)",
                     "description" => "Local llama-server, OpenAI-compatible",
                     "base_url" => "#{base_url}/v1/chat/completions",
                     "models" => [{ "name" => model_alias, "context_limit" => ctx }],
                     "supports_streaming" => true,
                     "requires_auth" => false,
                   })
        begin
          data = Psych.safe_load(GOOSE_CONFIG.read, permitted_classes: [Symbol, Date, Time], aliases: true) || {}
        rescue SystemCallError, Psych::Exception
          return false
        end
        data["GOOSE_PROVIDER"] = PROVIDER
        data["GOOSE_MODEL"] = model_alias
        data["active_provider"] = PROVIDER
        (data["providers"] ||= {})[PROVIDER] = { "enabled" => true, "model" => model_alias, "configured" => true }
        GOOSE_CONFIG.write(Psych.dump(data))
        true
      end

      def sync(settings)
        model_alias = settings.model.name
        ctx = settings.model.context_length
        handlers = {
          "hermes" => -> { sync_hermes(settings) },
          "goose" => -> { sync_goose(model_alias, ctx, settings.llama.base_url) },
          "crush" => -> { sync_crush(model_alias, ctx) },
          "opencode" => -> { sync_opencode(model_alias, ctx) },
          "pi" => -> { sync_pi(model_alias, ctx) },
        }
        CLIENTS.select { |name| handlers.fetch(name).call }
      end

      private

      def load_json(path)
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

      # Hermes is a client of llama-server like any other.
      #
      # Its managed keys are all LLM-derived (alias, base URL, context
      # length), so it belongs on this roster rather than in the agent-side
      # setup.
      def sync_hermes(settings)
        require_relative "agent/hermes"

        return false unless Agent::Hermes::CONFIG_PATH.dirname.directory?

        Agent::Hermes.sync_config(settings)
        true
      end
    end
  end
end
