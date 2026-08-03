require "json"
require "net/http"
require "socket"
require "pathname"

module Mimic
  module Probes
    class << self
      def which(name, path = ENV.fetch("PATH", ""))
        path.split(File::PATH_SEPARATOR).each do |dir|
          candidate = Pathname.new(dir) / name
          return candidate.to_s if candidate.file? && candidate.executable?
        end
        nil
      end

      def get(url, headers: {}, timeout: 3)
        uri = URI(url)
        req = Net::HTTP::Get.new(uri)
        headers.each { |k, v| req[k] = v }
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                         open_timeout: timeout, read_timeout: timeout) { |http| http.request(req) }
      end

      def http_json(url, headers: {}, timeout: 3)
        res = get(url, headers: headers, timeout: timeout)
        return nil unless res.is_a?(Net::HTTPSuccess)

        JSON.parse(res.body)
      rescue StandardError
        nil
      end

      def http_ok(url, headers: {}, timeout: 3)
        get(url, headers: headers, timeout: timeout).is_a?(Net::HTTPSuccess)
      rescue StandardError
        false
      end

      # Poll *condition* until it holds, the process dies, or *abort* fires.
      #
      # `alive` only covers the process we spawned. In llama.cpp router mode
      # the work happens in a grandchild the router respawns on demand, so its
      # death is invisible here -- `abort` is how a caller reports that
      # failure instead of waiting out every attempt.
      def wait_until(attempts: 30, delay: 2, alive: nil, label: nil, abort: nil)
        attempts.times do |attempt|
          return done(true, label) if yield
          return done(false, label) if alive && !alive.call
          return done(false, label) if abort&.call

          tick((attempt + 1) * delay, label)
          sleep(delay)
        end
        done(yield, label)
      end

      def wait_ready(url, headers: {}, attempts: 30, delay: 2, alive: nil, label: nil)
        wait_until(attempts: attempts, delay: delay, alive: alive, label: label) { http_ok(url, headers: headers, timeout: 1) }
      end

      # Non-blocking liveness check for a child spawned via Process.spawn --
      # reaps it if it has exited, unlike Process.kill(0, pid) which reports a
      # zombie as alive until something reaps it.
      def child_alive?(pid)
        Process.waitpid(pid, Process::WNOHANG).nil?
      rescue Errno::ECHILD
        false
      end

      def pid_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      # First two cmdline args joined -- covers shebang scripts where argv[0]
      # is the interpreter and argv[1] is the actual script path.
      def argv0(pid)
        raw = Pathname.new("/proc/#{pid}/cmdline").binread
        raw.split("\x00").first(2).join(" ")
      rescue SystemCallError
        nil
      end

      def read_pid(pid_file, expect)
        pid = Integer(pid_file.read.strip)
        a0 = argv0(pid)
        return nil if a0.nil? || !a0.include?(expect)

        pid
      rescue SystemCallError, ArgumentError, TypeError
        nil
      end

      # Scan /proc for a live process whose executable (argv[0]) contains *expect*.
      def find_pid_by_cmd(expect)
        Pathname.new("/proc").each_child do |entry|
          next unless entry.basename.to_s =~ /\A\d+\z/

          pid = entry.basename.to_s.to_i
          a0 = argv0(pid)
          return pid if a0&.include?(expect)
        end
        nil
      end

      def stop_pid(pid_file, expect)
        pid = read_pid(pid_file, expect)
        pid ||= find_pid_by_cmd(expect)

        pid_file.unlink if pid_file.exist?
        return false if pid.nil?

        Process.kill("TERM", group_leader?(pid) ? -pid : pid)
        true
      end

      # Whether a server could actually bind here right now.
      #
      # An HTTP probe goes quiet the moment the old server stops serving, but
      # its listening socket outlives that by the whole model-unload
      # teardown. Both engines bind through cpp-httplib with SO_REUSEADDR, so
      # mirror that: a TIME_WAIT leftover is not a conflict, a live listener
      # is.
      def port_free?(host, port)
        family = host.include?(":") ? Socket::AF_INET6 : Socket::AF_INET
        probe = Socket.new(family, Socket::SOCK_STREAM)
        probe.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
        begin
          probe.bind(Socket.pack_sockaddr_in(port, host))
        rescue SystemCallError
          return false
        ensure
          probe.close
        end
        true
      end

      private

      def tick(seconds, label)
        return unless label

        print "\r#{label} (#{seconds.to_i}s)"
        $stdout.flush
      end

      def done(result, label)
        puts if label
        result
      end

      # The launcher spawns with pgroup: true, so a pid from the pid file leads
      # its group and TERMing the group takes the router's grandchild with it.
      # A pid from the /proc scan need not lead anything, and `kill(-pid)` on a
      # non-leader raises ESRCH instead of stopping the server.
      def group_leader?(pid)
        Process.getpgid(pid) == pid
      rescue SystemCallError
        false
      end
    end
  end
end
