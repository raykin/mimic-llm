require "pathname"
require "timeout"
require_relative "../paths"
require_relative "../util/probes"

module Mimic
  module Engine
    # One llama-server process: where it records its pid, where it writes its
    # log, and how it is found and killed. Nothing here knows about models,
    # flags or engines -- the chat server and the embedding server are two
    # instances of this, differing only in their paths and in whether a
    # /proc scan may stand in for a missing pid file.
    class ServerProcess
      # The metadata block sits ~9 KB above a startup failure line, so the
      # tail has to reach back far enough to still see n_expert / n_layer.
      LOG_TAIL_BYTES = 64_000

      BINARY = "llama-server".freeze

      class << self
        def chat
          new(pid_file: Paths::PID_DIR / "llama-server.pid",
              log_file: Paths::LLM_RUN_DIR / "llama-server.log",
              proc_scan_fallback: true)
        end

        # The embedding server is one process with no children, so a scan for
        # "llama-server" could only ever find the chat server.
        def embed
          new(pid_file: Paths::PID_DIR / "llama-embed.pid",
              log_file: Paths::LLM_RUN_DIR / "llama-embed.log",
              proc_scan_fallback: false)
        end
      end

      attr_reader :pid_file, :log_file

      def initialize(pid_file:, log_file:, proc_scan_fallback:)
        @pid_file = pid_file
        @log_file = log_file
        @proc_scan_fallback = proc_scan_fallback
      end

      def proc_scan_fallback? = @proc_scan_fallback

      def log_tail(offset = 0)
        text = log_file.binread.force_encoding(Encoding::UTF_8).scrub
        text = text[offset..] || "" if offset.positive?
        text[-LOG_TAIL_BYTES..] || text
      rescue SystemCallError
        ""
      end

      def log_size = log_file.exist? ? log_file.size : 0

      def last_lines(text, n = 4)
        text.strip.lines.last(n).join
      end

      def pid
        pid_file.read.strip
      rescue SystemCallError
        nil
      end

      # This server's live pids, for the other server to leave alone.
      def pids
        live = Util::Probes.read_pid(pid_file, BINARY)
        live ? [live, *Util::Probes.descendants(live)] : []
      end

      def stop(exclude: [])
        Util::Probes.stop_pid(pid_file, BINARY, exclude: exclude, fallback: proc_scan_fallback?)
      end

      def cleanup_failed(spawned_pid)
        pid_file.unlink if pid_file.exist?
        return unless Util::Probes.child_alive?(spawned_pid)

        Process.kill("TERM", -spawned_pid)
        Timeout.timeout(10) { Process.waitpid(spawned_pid) }
      rescue Timeout::Error
        Process.kill("KILL", -spawned_pid)
        Process.waitpid(spawned_pid)
      rescue Errno::ECHILD
        nil
      end
    end
  end
end
