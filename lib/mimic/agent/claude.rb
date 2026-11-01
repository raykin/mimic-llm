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
      MIN_DYNAMIC_SECTIONS_VERSION = [2, 1, 98].freeze

      # Claude ignores a smaller CLAUDE_CODE_AUTO_COMPACT_WINDOW and warns on every launch.
      MIN_AUTO_COMPACT_WINDOW = 100_000
      # Claude reserves min(max output, 20k) + 3k before compacting; a cap at or above 20k gains no room.
      COMPACT_OUTPUT_RESERVE = 20_000
      OUTPUT_TOKEN_MAX = 32_000
      # Provider routing overrides ANTHROPIC_BASE_URL and would send the
      # session past llama-server.
      ENV_UNSET = %w[
        ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_UNIX_SOCKET
        CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_FOUNDRY_BASE_URL ANTHROPIC_FOUNDRY_RESOURCE
        CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_ANTHROPIC_AWS
        CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD CLAUDE_CODE_USE_MANTLE
      ].freeze

      # WebSearch/WebFetch are Anthropic server-executed tools -- llama.cpp's
      # /v1/messages bridge has no implementation (server log: "unsupported
      # Responses tool type 'web_search'"), so they silently no-op instead of
      # failing. Denied so the failure is visible; an MCP server named in
      # Paths::MCP_SERVERS_PATH can take the internet-access job over.
      DENIED_TOOLS = %w[WebSearch WebFetch].freeze

      # SHIM_DIR holds a `claude` that execs this result -- resolving to it
      # would loop.
      def self.find_binary
        path = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).reject { |p| p == SHIM_DIR.to_s }.join(File::PATH_SEPARATOR)
        Util::Probes.which("claude", path)
      end

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

      def ensure_config_dir
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

      # Whatever the user opted into, or nothing.
      def mcp_servers
        JSON.parse(Paths::MCP_SERVERS_PATH.read)
      rescue SystemCallError, JSON::ParserError
        {}
      end

      # Seeds/refreshes those entries in the isolated .claude.json -- merged,
      # not overwritten, since CC writes its own runtime state (onboarding,
      # tips, startup counts) into this same file and the user may have added
      # servers of their own.
      def merge_mcp_config(seed)
        wanted = mcp_servers
        return if wanted.empty?

        data = seed.exist? ? JSON.parse(seed.read) : {}
        current = data["mcpServers"].is_a?(Hash) ? data["mcpServers"] : {}
        return if wanted.all? { |name, spec| current[name] == spec }

        data["mcpServers"] = current.merge(wanted)
        seed.write("#{JSON.generate(data)}\n")
      rescue JSON::ParserError
        nil
      end

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

      # Status line whose ctx denominator is the served window.
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
          "CLAUDE_CONFIG_DIR" => ensure_config_dir.to_s,
        }
      end

      # Claude applies user/project settings env after the process env, so
      # the local env is pinned again here, at the command-line tier, with
      # ENV_UNSET blanked.
      # A forwarded --settings (user) sits underneath: Claude keeps only the
      # last --settings, so it is merged in rather than passed separately.
      def settings_overlay(model_id, user = {})
        pinned = local_env(@settings.llama.base_url, Agent::AUTH_TOKEN, model_entry).except("CLAUDE_CONFIG_DIR")
        overlay = {
          "env" => ENV_UNSET.to_h { |name| [name, ""] }.merge(
            pinned,
            "CLAUDE_CODE_ATTRIBUTION_HEADER" => "0",
            "CLAUDE_CODE_SUBAGENT_MODEL" => "inherit",
          ),
          "availableModels" => [model_id],
          # A user's apiKeyHelper would still run and send its cloud key to llama-server.
          "apiKeyHelper" => "",
          "permissions" => { "ask" => %w[Task Agent], "deny" => DENIED_TOOLS },
          "statusLine" => status_line,
        }
        user.merge(
          overlay,
          "env" => user.fetch("env", {}).merge(overlay["env"]),
          "permissions" => joined_permissions(user.fetch("permissions", {}), overlay["permissions"]),
        )
      end

      def joined_permissions(user, mimic)
        user.merge(mimic) { |_rule, theirs, ours| theirs.is_a?(Array) ? (theirs + ours).uniq : ours }
      end

      def flags(model_id, user = {})
        settings = ["--settings", JSON.generate(settings_overlay(model_id, user))]
        current = version
        return settings if current && !Agent.version_at_least?(current, MIN_DYNAMIC_SECTIONS_VERSION)

        [DYNAMIC_SECTIONS_FLAG, *settings]
      end

      def local_env(base, key, entry)
        env = {
          "ANTHROPIC_BASE_URL" => base,
          "ANTHROPIC_AUTH_TOKEN" => key,
          "ANTHROPIC_MODEL" => entry["id"],
          "CLAUDE_CODE_ATTRIBUTION_HEADER" => "0",
          # Per-tool countdown reminders change the system prefix.
          "CLAUDE_CODE_TOTAL_TOKENS_REMINDER" => "off",
          "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" => "1",
          "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS" => "1",
          "CLAUDE_CODE_NO_FLICKER" => "1",
        }
        window = entry["context_length"]&.to_i
        if window
          # Claude assumes 200k for a model id it does not know and clamps
          # AUTO_COMPACT_WINDOW to [100k, that]; MAX_CONTEXT_TOKENS sets the window.
          env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] = window.to_s
          # Blank, not omitted, below the minimum so an inherited value cannot apply.
          env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = window >= MIN_AUTO_COMPACT_WINDOW ? window.to_s : ""
          env["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"] = "90"
          output = [window / 4, OUTPUT_TOKEN_MAX].min.clamp(1..)
          env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = output.to_s if output < COMPACT_OUTPUT_RESERVE
        end
        env.merge(extra_env)
      end

      # An unreadable forwarded --settings keeps the old order: it goes
      # first and mimic's overlay, applied last, replaces it.
      def command(model_id, extra_args)
        user_settings, rest = split_user_settings(extra_args)
        user = read_user_settings(user_settings)
        return ["claude", "--model", model_id, *flags(model_id, user), *rest] if user

        ["claude", *user_settings, "--model", model_id, *flags(model_id), *rest]
      end

      # The forwarded --settings values merged in order, each inline JSON or
      # a file path, or nil when one cannot be read.
      def read_user_settings(settings_args)
        values = []
        index = 0
        while index < settings_args.length
          if settings_args[index] == "--settings"
            values << settings_args[index + 1]
            index += 2
          else
            values << settings_args[index].delete_prefix("--settings=")
            index += 1
          end
        end
        values.reduce({}) do |merged, value|
          text = value.lstrip.start_with?("{") ? value : File.read(File.expand_path(value))
          loaded = JSON.parse(text)
          return nil unless loaded.is_a?(Hash) && %w[env permissions].all? { |key| loaded.fetch(key, {}).is_a?(Hash) }

          merged.merge(
            loaded,
            "env" => merged.fetch("env", {}).merge(loaded.fetch("env", {})),
            "permissions" => merged.fetch("permissions", {}).merge(loaded.fetch("permissions", {})),
          )
        end
      rescue SystemCallError, JSON::ParserError
        nil
      end

      # A forwarded --settings goes before mimic's, so mimic's overlay is the
      # one Claude applies last. Anything after `--` stays where it is.
      def split_user_settings(args)
        separator = args.index("--") || args.length
        head = args[0...separator]
        user_settings = []
        rest = []
        index = 0
        while index < head.length
          arg = head[index]
          if arg == "--settings" && index + 1 < head.length
            user_settings.push(arg, head[index + 1])
            index += 2
            next
          end
          (arg.start_with?("--settings=") ? user_settings : rest) << arg
          index += 1
        end
        [user_settings, rest + args[separator..]]
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
