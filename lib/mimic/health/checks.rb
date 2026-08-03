require "net/http"
require "sqlite3"
require "timeout"
require "open3"
require_relative "../config"
require_relative "../paths"
require_relative "../probes"
require_relative "../services/hermes"
require_relative "../services/llama"

module Mimic
  module Health
    # The install/service probes `verify` reports on. Each answers with a
    # Result rather than raising, so one dead component never hides the rest.
    class Checks
      class << self
        # Probe a service endpoint.
        def service(url, headers: {}, timeout: 5)
          res = Probes.get(url, headers: headers, timeout: timeout)
          Result.new(ok: res.is_a?(Net::HTTPSuccess), message: "HTTP #{res.code}")
        rescue StandardError => e
          Result.error(e.message)
        end
      end

      def initialize(settings)
        @settings = settings
      end

      # [[component name, Result], ...] in report order.
      def to_a
        [
          ["llama.cpp", self.class.service(Services::Llama.new(@settings).models_url)],
          ["Hermes binary", hermes_install],
          ["Hermes DB", db],
          ["claude-code", claude_code],
          ["Claude config dir", claude_config_dir],
        ]
      end

      private

      # Check Hermes state DB is accessible and has active sessions.
      def db
        handle = SQLite3::Database.new(Config::STATE_DB.to_s, readonly: true)
        begin
          rows, tokens = handle.execute(
            "SELECT (SELECT COUNT(*) FROM messages WHERE active=1)," \
            " (SELECT COALESCE(SUM(input_tokens+output_tokens),0) FROM sessions)"
          ).first
          Result.ok("#{rows} messages, #{tokens || 0} tokens total")
        ensure
          handle.close
        end
      rescue StandardError => e
        Result.error(e.message)
      end

      # Verify claude-code binary exists and reports version.
      def claude_code
        out, status = Timeout.timeout(5) { Open3.capture2("claude", "--version") }
        Result.new(ok: status.success?, message: out.strip)
      rescue Errno::ENOENT
        Result.error("not found")
      rescue StandardError => e
        Result.error(e.message)
      end

      # Hermes binary -- the venv one if present, else whatever is on PATH.
      def hermes_install
        binary = Services::Hermes.find_binary
        return Result.error("not found (looked in #{Config::HERMES_VENV}/bin, PATH)") if binary.nil?

        Result.ok(binary)
      end

      # The isolated config dir Claude Code runs against.
      #
      # Absent is not a failure: claude_env() creates and seeds it on every
      # launch, so it simply means no local Claude Code session has started
      # yet.
      def claude_config_dir
        config_dir = Paths::CLAUDE_CONFIG_DIR
        return Result.ok("#{config_dir} (created on first launch)") unless config_dir.directory?

        seeded = (config_dir / ".claude.json").exist?
        Result.ok("#{config_dir}#{seeded ? '' : ' (not yet seeded)'}")
      end
    end
  end
end
