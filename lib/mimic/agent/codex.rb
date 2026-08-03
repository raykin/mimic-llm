require "json"
require "pathname"
require "open3"
require_relative "../paths"
require_relative "../probes"

module Mimic
  module Agent
    class Codex
      PROFILE = "unsloth_api"
      ENV_KEY = "UNSLOTH_STUDIO_AUTH_TOKEN"
      PROVIDER_HEADER = "[model_providers.#{PROFILE}]"
      MODEL_CATALOG_MIN_VERSION = [0, 110, 0].freeze
      FALLBACK_PROMPT = Pathname.new(__dir__) / "codex_fallback_prompt.md"

      MANAGED_KEYS = /\s*(oss_provider|model_provider|model|model_context_window)\s*=/

      def initialize(settings)
        @settings = settings
      end

      def launch(extra_args)
        if Probes.which("codex").nil? && !ENV["MIMIC_ALLOW_INSTALL"]
          abort "codex binary not found -- install it with `npm install -g @openai/codex`"
        end

        entry = model_entry
        base = @settings.base_url
        seed_home
        write_config(base, entry)
        launch_env = { ENV_KEY => Agent::AUTH_TOKEN, "CODEX_HOME" => home.to_s }
        puts "mimic ready at #{base} · model #{entry['id']}"
        code = Agent.spawn_and_wait(command(extra_args), launch_env)
        raise SystemExit, code if code&.nonzero?
      end

      private

      def model_entry
        { "id" => @settings.model_alias, "context_length" => @settings.context_length }
      end

      def merge_config(existing, base)
        chunks = existing.split(/(?=^\[)/)
        chunks[0] = "" if chunks.empty?
        unless chunks[0].to_s.match?(/^\s*oss_provider\s*=/)
          chunks[0] = chunks[0].to_s
          chunks[0] += "\n" unless chunks[0].empty? || chunks[0].end_with?("\n")
          chunks[0] += "oss_provider = \"#{PROFILE}\"\n"
        end
        stale = [PROVIDER_HEADER, "#{PROVIDER_HEADER[0..-2]}."]
        text = chunks.reject { |c| stale.any? { |s| c.start_with?(s) } }.join
        text += "\n" unless text.end_with?("\n")
        text += "\n" unless text.end_with?("\n\n")
        text +
          "#{PROVIDER_HEADER}\n" \
          "name = \"Unsloth Studio\"\n" \
          "base_url = #{JSON.generate("#{base}/v1")}\n" \
          "env_key = \"#{ENV_KEY}\"\n" \
          "wire_api = \"responses\"\n" \
          "requires_openai_auth = false\n"
      end

      def supports_model_catalog?
        executable = Probes.which("codex")
        return true if executable.nil?

        out, status = Open3.capture2(executable, "--version")
        return false unless status.success?

        match = out.match(/(\d+)\.(\d+)\.(\d+)/)
        return false unless match

        Agent.version_at_least?(match.captures.map(&:to_i), MODEL_CATALOG_MIN_VERSION)
      rescue Errno::ENOENT
        false
      end

      # Conservative metadata for a model unknown to Codex's built-in catalog.
      def model_catalog(model)
        window = model["context_length"]
        entry = {
          "slug" => model["id"],
          "display_name" => model["id"],
          "description" => "Model served by llama-server",
          "supported_reasoning_levels" => [],
          "shell_type" => "default",
          "visibility" => "none",
          "supported_in_api" => true,
          "priority" => 99,
          "availability_nux" => nil,
          "upgrade" => nil,
          "base_instructions" => FALLBACK_PROMPT.read,
          "supports_reasoning_summaries" => false,
          "supports_reasoning_summary_parameter" => false,
          "support_verbosity" => false,
          "default_verbosity" => nil,
          "apply_patch_tool_type" => nil,
          "truncation_policy" => { "mode" => "bytes", "limit" => 10_000 },
          "supports_parallel_tool_calls" => false,
          "experimental_supported_tools" => [],
        }
        if window
          entry["context_window"] = window.to_i
          entry["max_context_window"] = window.to_i
        end
        { "models" => [entry] }
      end

      def write_config(base, model)
        home.mkpath
        config = home / "config.toml"
        existing = config.exist? ? config.read : ""
        merged = merge_config(existing, base)
        config.write(merged) if merged != existing

        profile_text = +"oss_provider = \"#{PROFILE}\"\n" \
                        "model_provider = \"#{PROFILE}\"\n" \
                        "model = #{JSON.generate(model['id'])}\n"
        if supports_model_catalog? && FALLBACK_PROMPT.file?
          catalog = home / "model-catalog.json"
          catalog_text = "#{JSON.pretty_generate(model_catalog(model))}\n"
          catalog.write(catalog_text) if !catalog.exist? || catalog.read != catalog_text
          profile_text << "model_catalog_json = #{JSON.generate(catalog.basename.to_s)}\n"
        end
        window = model["context_length"]
        profile_text << "model_context_window = #{window.to_i}\n" if window
        profile = home / "#{PROFILE}.config.toml"
        profile.write(profile_text) if !profile.exist? || profile.read != profile_text
      end

      def command(extra_args)
        ["codex", "--oss", "--profile", PROFILE, *extra_args]
      end

      def strip_newlines(s)
        s.sub(/\A\n+/, "").sub(/\n+\z/, "")
      end

      # Carry the user's own Codex settings into the agent home, minus
      # provider wiring: MCP servers, project trust, approval policy and
      # personality stay; model/provider selection belongs to write_config.
      def seed_config(text)
        chunks = text.split(/^(?=\[)/)
        # each_line + chomp: no trailing empty element for a final newline,
        # unlike String#split("\n").
        preamble = chunks[0].to_s.each_line.map(&:chomp).reject { |line| line.match?(MANAGED_KEYS) }.join("\n")
        tables = chunks[1..].to_a.reject { |c| c.start_with?("[model_providers.") }
        "#{strip_newlines([strip_newlines(preamble), *tables].join("\n"))}\n"
      end

      def home
        Paths::AGENTS_DIR / "codex"
      end

      # Give the agent home a starting config once, then never touch it
      # again -- only provider wiring is refreshed on each launch by
      # write_config.
      def seed_home
        target = home
        target.mkpath(mode: 0o700)
        session = target / "config.toml"
        return if session.exist?

        user_config = Pathname.new(Dir.home) / ".codex/config.toml"
        session.write(user_config.file? ? seed_config(user_config.read) : "")
      end
    end
  end
end
