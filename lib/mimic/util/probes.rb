require "json"
require "net/http"
require "socket"
require "pathname"

module Mimic
  module Util
      module Probes
        STOP_WAIT_ATTEMPTS = 100
        STOP_WAIT_DELAY = 0.1

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

        def post(url, body, timeout: 10)
          uri = URI(url)
          req = Net::HTTP::Post.new(uri)
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(body)
          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                          open_timeout: timeout, read_timeout: timeout) { |http| http.request(req) }
        rescue StandardError
          nil
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

        # Every pid below *pid* in the process tree. llama.cpp's router owns the
        # port while a child owns the CUDA context, so anything asking what the
        # server holds has to ask about the children too.
        def descendants(pid)
          children = Hash.new { |hash, key| hash[key] = [] }
          Pathname.new("/proc").each_child do |entry|
            name = entry.basename.to_s
            next unless name =~ /\A\d+\z/

            parent = ppid(name.to_i)
            children[parent] << name.to_i if parent
          end

          found = []
          queue = children[pid.to_i].dup
          until queue.empty?
            current = queue.shift
            next if found.include?(current)

            found << current
            queue.concat(children[current])
          end
          found
        end

        # First two cmdline args joined -- covers shebang scripts where argv[0]
        # is the interpreter and argv[1] is the actual script path.
        def argv0(pid)
          raw = Pathname.new("/proc/#{pid}/cmdline").binread
          raw.split("\x00").first(2).join(" ")
        rescue SystemCallError
          nil
        end

        # The comm field is parenthesised and may itself contain spaces or
        # parentheses, so ppid is counted from the last ')' rather than by
        # splitting the whole line.
        def ppid(pid)
          stat = Pathname.new("/proc/#{pid}/stat").read
          fields = stat[(stat.rindex(")") || -1) + 1..].to_s.split
          Integer(fields[1])
        rescue SystemCallError, ArgumentError, TypeError
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

        # Scan /proc for a live process whose executable (argv[0]) contains
        # *expect*, ignoring the pids in *exclude*. The chat and embedding
        # servers are the same binary, so argv[0] alone cannot separate them.
        def find_pid_by_cmd(expect, exclude: [])
          Pathname.new("/proc").each_child do |entry|
            next unless entry.basename.to_s =~ /\A\d+\z/

            pid = entry.basename.to_s.to_i
            next if exclude.include?(pid)

            a0 = argv0(pid)
            return pid if a0&.include?(expect)
          end
          nil
        end

        # *fallback* is what makes the /proc scan optional: it rescues a router
        # whose pid file was lost, but for a single-process server it can only
        # ever match the other server running the same binary.
        def stop_pid(pid_file, expect, exclude: [], fallback: true)
          pid = read_pid(pid_file, expect)
          pid ||= find_pid_by_cmd(expect, exclude: exclude) if fallback

          pid_file.unlink if pid_file.exist?
          return false if pid.nil?

          group = group_leader?(pid)
          target = group ? -pid : pid
          stopped_pids = [pid, *descendants(pid)]
          Process.kill("TERM", target)
          return true if wait_for_process_exit(stopped_pids)

          Process.kill("KILL", target)
          wait_for_process_exit(stopped_pids)
          true
        rescue Errno::ESRCH
          true
        end

        # Whether a server could actually bind here right now.
        #
        # An HTTP probe goes quiet the moment the old server stops serving, but
        # its listening socket outlives that by the whole model-unload
        # teardown. Test for a listener first, then mirror the engines' reuse
        # options when checking whether a new server may bind. Binding with
        # SO_REUSEPORT alone is not a listener check: it can succeed beside a
        # live server in the same reuse group.
        def port_free?(host, port)
          connect_host = { "0.0.0.0" => "127.0.0.1", "::" => "::1" }.fetch(host, host)
          listener = Socket.tcp(connect_host, port, connect_timeout: 0.2)
          listener.close
          return false
        rescue Errno::ECONNREFUSED
          family = host.include?(":") ? Socket::AF_INET6 : Socket::AF_INET
          probe = Socket.new(family, Socket::SOCK_STREAM)
          probe.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
          probe.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEPORT, true) if defined?(Socket::SO_REUSEPORT)
          begin
            probe.bind(Socket.pack_sockaddr_in(port, host))
          rescue SystemCallError
            return false
          ensure
            probe.close
          end
          true
        rescue SystemCallError
          false
        end

        private

        def wait_for_process_exit(pids)
          wait_until(attempts: STOP_WAIT_ATTEMPTS, delay: STOP_WAIT_DELAY) do
            pids.all? { |pid| process_exited?(pid) }
          end
        end

        def process_exited?(pid)
          !Process.waitpid(pid, Process::WNOHANG).nil?
        rescue Errno::ECHILD
          !pid_alive?(pid)
        end

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
end
