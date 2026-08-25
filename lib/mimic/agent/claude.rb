require "json"
require "pathname"
require "open3"
require_relative "../paths"
require_relative "../util/probes"

module Mimic
  module Agent
    class Claude
      SHIM_DIR = Paths::STATE_DIR / "bin"

      DYNAMIC_SECTIONS_FLAG = "--exclude-dynamic-system-prompt-sections"
      MIN_SETTINGS_VERSION = [2, 1, 98].freeze
      ENV_UNSET = %w[ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN].freeze

      # WebSearch/WebFetch are Anthropic server-executed tools -- llama.cpp's
      # /v1/messages bridge has no implementation (server log: "unsupported
      # Responses tool type 'web_search'"), so they silently no-op instead of
      # failing. Deny them and give c4ai MCP the internet-access job instead.
      DENIED_TOOLS = %w[WebSearch WebFetch].freeze
      C4AI_MCP_SERVER = {
        "command" => "python",
        "args" => ["-m", "c4ai_mcp.fastmcp_server"],
      }.freeze

      # SHIM_DIR holds a `claude` that execs this result -- resolving to it
      # would loop.
      def self.find_binary
        path = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).reject { |p| p == SHIM_DIR.to_s }.join(File::PATH_SEPARATOR)
        Util::Probes.which("claude", path)
      end

      def self.ensure_config_dir
        config_dir = Paths::CLAUDE_CONFIG_DIR
        config_dir.mkpath
        seed = config_dir / ".claude.json"
        seed.write("#{JSON.generate({ hasCompletedOnboarding: true })}\n") unless seed.exist?
        settings_file = config_dir / "settings.json"
        user_settings = Pathname.new(Dir.home) / ".claude" / "settings.json"
        settings_file.make_symlink(user_settings) if !settings_file.exist? && user_settings.exist?
        merge_mcp_config(seed)
        config_dir
      end

      # Seeds/refreshes the c4ai MCP entry in the isolated .claude.json --
      # merged, not overwritten, since CC writes its own runtime state
      # (onboarding, tips, startup counts) into this same file.
      def self.merge_mcp_config(seed)
        data = seed.exist? ? JSON.parse(seed.read) : {}
        return if data["mcpServers"].is_a?(Hash) && data["mcpServers"]["c4ai"] == C4AI_MCP_SERVER

        data["mcpServers"] ||= {}
        data["mcpServers"]["c4ai"] = C4AI_MCP_SERVER
        seed.write("#{JSON.generate(data)}\n")
      rescue JSON::ParserError
        nil
      end
      private_class_method :merge_mcp_config

      def initialize(settings)
        @settings = settings
      end

      # The environment `mimic claude` would launch with, without launching.
      # Used for the hermes-lcc bridge, where Hermes spawns Claude Code
      # itself, so the bridge gets the same context/KV-cache handling.
      def env
        entry = model_entry
        base = @settings.llama.base_url
        # env diff (not a full merge): Process.exec/spawn apply a Hash first
        # arg as a diff on top of the inherited environment -- a key must be
        # explicit `=> nil` to unset it, omitting it leaves it inherited.
        result = local_env(base, Agent::AUTH_TOKEN, entry)
        ENV_UNSET.each { |name| result[name] = nil }
        if self.class.find_binary
          # Everything command() puts before the caller's own arguments: a
          # bare `claude` typed by Hermes' skill has to reach the same model
          # and overlay as `mimic claude` does.
          shim = write_shim(command(entry["id"], [])[1..])
          result["PATH"] = [shim.dirname.to_s, ENV.fetch("PATH", "")].join(File::PATH_SEPARATOR)
        end
        result
      end

      def launch(extra_args)
        abort "claude binary not found -- install Claude Code first" if self.class.find_binary.nil?

        entry = model_entry
        base = @settings.llama.base_url
        launch_env = local_env(base, Agent::AUTH_TOKEN, entry)
        ENV_UNSET.each { |name| launch_env[name] = nil }
        puts "mimic ready at #{base} · model #{entry['id']}"
        code = Agent.spawn_and_wait(command(entry["id"], extra_args), launch_env)
        raise SystemExit, code if code&.nonzero?
      end

      private

      def model_entry
        { "id" => @settings.model.name, "context_length" => @settings.model.context_length }
      end

      def version
        executable = Util::Probes.which("claude")
        return nil if executable.nil?

        out, = Open3.capture2(executable, "--version")
        match = out.match(/(\d+)\.(\d+)\.(\d+)/)
        match ? match.captures.map(&:to_i) : [0]
      rescue Errno::ENOENT
        [0]
      end

      # Status line whose ctx denominator is the served window, not Claude's
      # guess. Claude Code has no way to be told a custom model's context
      # window, so bake the real ctx in here.
      def status_line
        used = %w[input_tokens cache_creation_input_tokens cache_read_input_tokens]
               .map { |field| "(.context_window.current_usage.#{field} // 0)" }.join(" + ")
        window = @settings.model.context_length.to_i
        jq = %("\\(.model.display_name) | effort: \\(.effort.level // "?") | ctx \\(((#{used}) / 1000) | floor)K/#{window / 1000}K")
        { "type" => "command", "command" => "jq -r '#{jq}'" }
      end

      # mimic's Claude Code settings on top of upstream's defaults. Model
      # aliases keep subagent/haiku routing on the local model instead of a
      # cloud one that isn't served here. COMMENT_GATE_OFF spares the served
      # model: the gate's judge call lands on the same single-slot llama-server
      # and evicts the session's cached prefix, costing a full re-prefill.
      def extra_env
        model_alias = @settings.model.name
        {
          "COMMENT_GATE_OFF" => "1",
          "ANTHROPIC_CUSTOM_MODEL_OPTION" => model_alias,
          "ANTHROPIC_SMALL_FAST_MODEL" => model_alias,
          "ANTHROPIC_DEFAULT_HAIKU_MODEL" => model_alias,
          "ANTHROPIC_DEFAULT_SONNET_MODEL" => model_alias,
          "ANTHROPIC_DEFAULT_OPUS_MODEL" => model_alias,
          "CLAUDE_CONFIG_DIR" => self.class.ensure_config_dir.to_s,
        }
      end

      def settings_overlay(model_id)
        {
          "env" => {
            "CLAUDE_CODE_ATTRIBUTION_HEADER" => "0",
            "CLAUDE_CODE_SUBAGENT_MODEL" => "inherit",
          },
          "availableModels" => [model_id],
          "permissions" => { "ask" => %w[Task Agent], "deny" => DENIED_TOOLS },
          "statusLine" => status_line,
        }
      end

      def flags(model_id)
        current = version
        return [] if current && !Agent.version_at_least?(current, MIN_SETTINGS_VERSION)

        [DYNAMIC_SECTIONS_FLAG, "--settings", JSON.generate(settings_overlay(model_id))]
      end

      def local_env(base, key, entry)
        env = {
          "ANTHROPIC_BASE_URL" => base,
          "ANTHROPIC_AUTH_TOKEN" => key,
          "ANTHROPIC_MODEL" => entry["id"],
          "CLAUDE_CODE_ATTRIBUTION_HEADER" => "0",
          "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" => "1",
          "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS" => "1",
          "CLAUDE_CODE_NO_FLICKER" => "1",
        }
        window = entry["context_length"]
        if window
          env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = window.to_s
          env["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"] = "90"
        end
        env.merge(extra_env)
      end

      def command(model_id, extra_args)
        ["claude", "--model", model_id, *flags(model_id), *extra_args]
      end

      # A `claude` that re-applies upstream's launch flags to any invocation.
      # Hermes' claude-code skill types its own `claude ...` command line, so
      # the only place to reattach the --settings overlay is a PATH shim.
      def write_shim(launch_flags)
        SHIM_DIR.mkpath
        shim = SHIM_DIR / "claude"
        real = Pathname.new(self.class.find_binary).realpath.to_s
        shim.write(<<~SH)
          #!/usr/bin/env ruby
          REAL = #{real.inspect}
          FLAGS = #{launch_flags.inspect}
          exec(REAL, *FLAGS, *ARGV)
        SH
        shim.chmod(0o755)
        shim
      end
    end
  end
end
