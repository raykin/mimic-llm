require "pathname"
require "timeout"
require_relative "../paths"
require_relative "../util/probes"
require_relative "../util/host"

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

      # Both offsets are byte counts (`log_size` is a file size), so the
      # slicing has to stay on the binary string. Decoding first turns them
      # into character indexes, and one multi-byte character anywhere in a
      # long log makes `offset` overshoot the end and the tail come back
      # empty -- which is how a startup failure printed its own error line to
      # the log and nothing to the caller.
      def log_tail(offset = 0)
        bytes = log_file.binread
        bytes = bytes.byteslice(offset..) || "" if offset.positive?
        bytes = bytes.byteslice(-LOG_TAIL_BYTES..) || bytes
        bytes.force_encoding(Encoding::UTF_8).scrub
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

      # VRAM this server is holding, for a preflight that budgets a launch
      # meant to replace it: the driver's free figure counts it as unavailable,
      # but stopping this server hands it back.
      def gpu_mib
        live = pids
        return 0 if live.empty?

        Util::Host.gpu_process_mib(live) || 0
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
