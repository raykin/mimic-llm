require_relative "../../lib/mimic"
require "tmpdir"
require "socket"

RSpec.describe Mimic::Util::Probes do
  describe ".wait_until" do
    it "returns true as soon as the condition holds" do
      calls = 0
      expect(described_class.wait_until(attempts: 10, delay: 0) { (calls += 1) >= 3 }).to be true
      expect(calls).to eq(3)
    end

    it "returns false once the alive check fails" do
      alive = -> { false }
      expect(described_class.wait_until(attempts: 10, delay: 0, alive: alive) { false }).to be false
    end

    it "returns false as soon as abort fires" do
      expect(described_class.wait_until(attempts: 10, delay: 0, abort: -> { true }) { false }).to be false
    end

    it "gives up after exhausting all attempts" do
      expect(described_class.wait_until(attempts: 2, delay: 0) { false }).to be false
    end
  end

  describe ".child_alive?" do
    it "is true when waitpid reports the child hasn't exited (WNOHANG -> nil)" do
      allow(Process).to receive(:waitpid).with(123, Process::WNOHANG).and_return(nil)
      expect(described_class.child_alive?(123)).to be true
    end

    it "is false once waitpid reaps the child" do
      allow(Process).to receive(:waitpid).with(123, Process::WNOHANG).and_return(123)
      expect(described_class.child_alive?(123)).to be false
    end

    it "is false when the pid is unknown to this process" do
      allow(Process).to receive(:waitpid).and_raise(Errno::ECHILD)
      expect(described_class.child_alive?(999)).to be false
    end
  end

  describe ".pid_alive?" do
    it "is true when the signal can be delivered" do
      allow(Process).to receive(:kill).with(0, 111).and_return(1)
      expect(described_class.pid_alive?(111)).to be true
    end

    it "is false when the process doesn't exist" do
      allow(Process).to receive(:kill).and_raise(Errno::ESRCH)
      expect(described_class.pid_alive?(111)).to be false
    end
  end

  describe ".stop_pid" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = Pathname.new(dir)
        @spawned = []
        example.run
      ensure
        @spawned.each { |pid| Process.kill("KILL", pid) rescue nil }
        @spawned.each { |pid| Process.wait(pid) rescue nil }
      end
    end

    def spawn(*argv, **opts)
      pid = Process.spawn(*argv, **opts)
      @spawned << pid
      pid
    end

    def gone?(pid)
      described_class.wait_until(attempts: 40, delay: 0.05) do
        begin
          Process.waitpid(pid, Process::WNOHANG)
        rescue Errno::ECHILD
          nil
        end
        !described_class.pid_alive?(pid)
      end
    end

    def pid_file_for(pid) = (@dir / "server.pid").tap { |file| file.write(pid.to_s) }

    # Regression: both engines spawn with pgroup: true specifically so the
    # router's grandchild model process shares the parent's process group.
    # Sending TERM to the bare pid only kills the router, leaving the
    # VRAM-holding grandchild running and orphaned.
    it "stops the whole process group, grandchild included" do
      router = spawn("sh", "-c", "sleep 30 & wait", pgroup: true)
      described_class.wait_until(attempts: 40, delay: 0.05) { described_class.descendants(router).any? }
      model = described_class.descendants(router).first

      expect(described_class.stop_pid(pid_file_for(router), "sh")).to be true
      expect(gone?(router)).to be true
      expect(gone?(model)).to be true
    end

    # The /proc fallback hands back whatever pid matched, which need not lead
    # a group. `kill(-pid)` then raises ESRCH out of `llm stop` and the server
    # keeps running -- exactly the case the fallback exists to handle.
    it "stops a fallback match that does not lead a process group" do
      server = spawn("sleep", "31.123")

      expect(described_class.stop_pid(@dir / "absent.pid", "sleep 31.123")).to be true
      expect(gone?(server)).to be true
    end

    it "stops the bare pid when the group cannot be determined" do
      server = spawn("sleep", "30", pgroup: true)
      allow(Process).to receive(:getpgid).and_raise(Errno::ESRCH)

      expect(described_class.stop_pid(pid_file_for(server), "sleep")).to be true
      expect(gone?(server)).to be true
    end

    it "kills the process group when graceful shutdown exceeds the bound" do
      stub_const("Mimic::Util::Probes::STOP_WAIT_ATTEMPTS", 2)
      stub_const("Mimic::Util::Probes::STOP_WAIT_DELAY", 0.05)
      server = spawn("sh", "-c", "trap '' TERM; sleep 30", pgroup: true)
      described_class.wait_until(attempts: 40, delay: 0.05) { described_class.descendants(server).any? }

      expect(described_class.stop_pid(pid_file_for(server), "sh")).to be true
      expect(gone?(server)).to be true
    end

    # Both servers are the same binary, so the /proc fallback cannot tell
    # them apart on argv[0] alone -- stopping the chat server must not take
    # the embedding server with it.
    it "skips excluded pids in the fallback scan" do
      embed = spawn("sleep", "32.123")

      expect(described_class.stop_pid(@dir / "absent.pid", "sleep 32.123", exclude: [embed])).to be false
      expect(described_class.pid_alive?(embed)).to be true
    end

    it "does not scan /proc at all when the fallback is off" do
      server = spawn("sleep", "33.123")

      expect(described_class.stop_pid(@dir / "absent.pid", "sleep 33.123", fallback: false)).to be false
      expect(described_class.pid_alive?(server)).to be true
    end

    it "returns false and leaves no pid file when no matching process is found" do
      pid_file = pid_file_for(999_999)

      expect(described_class.stop_pid(pid_file, "no-such-server-anywhere")).to be false
      expect(pid_file).not_to exist
    end
  end

  describe ".port_free?" do
    it "joins the engines' reuse-port group when the platform supports it" do
      skip "SO_REUSEPORT is unavailable" unless defined?(Socket::SO_REUSEPORT)

      allow(Socket).to receive(:tcp).and_raise(Errno::ECONNREFUSED)
      probe = instance_double(Socket, bind: nil, close: nil)
      allow(Socket).to receive(:new).and_return(probe)
      allow(Socket).to receive(:pack_sockaddr_in).and_return("address")
      allow(probe).to receive(:setsockopt)

      expect(described_class.port_free?("127.0.0.1", 8080)).to be true
      expect(probe).to have_received(:setsockopt).with(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
      expect(probe).to have_received(:setsockopt).with(Socket::SOL_SOCKET, Socket::SO_REUSEPORT, true)
    end

    it "does not call a reuse-compatible bind while a listener is active" do
      listener = instance_double(Socket, close: nil)
      allow(Socket).to receive(:tcp).and_return(listener)
      allow(Socket).to receive(:new)

      expect(described_class.port_free?("0.0.0.0", 8080)).to be false
      expect(Socket).to have_received(:tcp).with("127.0.0.1", 8080, connect_timeout: 0.2)
      expect(Socket).not_to have_received(:new)
    end

    it "is true for a genuinely free port" do
      free_port = 0
      server = TCPServer.new("127.0.0.1", free_port)
      port = server.addr[1]
      server.close
      expect(described_class.port_free?("127.0.0.1", port)).to be true
    end

    it "is false instead of raising when the bind is refused outright" do
      expect(described_class.port_free?("127.0.0.1", 80)).to be false
    end

    it "is false while another socket holds the port" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      expect(described_class.port_free?("127.0.0.1", port)).to be false
    ensure
      server.close
    end
  end

  describe ".http_json" do
    around do |example|
      @server = TCPServer.new("127.0.0.1", 0)
      @thread = Thread.new { serve }
      example.run
    ensure
      @thread&.kill
      @server.close
    end

    def serve
      loop do
        client = @server.accept
        client.gets
        body = '{"error":"boom"}'
        client.print("HTTP/1.1 #{@status} Nope\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
        client.close
      end
    end

    def url = "http://127.0.0.1:#{@server.addr[1]}/"

    # Python's urlopen raises on a 4xx/5xx, so http_json answers None and the
    # caller reads "no data". Parsing the error body instead hands a caller
    # checking `if data` a truthy answer from a failing server.
    it "is nil for a 500 that still returns a JSON body" do
      @status = 500
      expect(described_class.http_json(url, timeout: 2)).to be_nil
    end
  end

  describe ".which" do
    it "finds an executable file on PATH" do
      expect(described_class.which("ruby", ENV.fetch("PATH", ""))).not_to be_nil
    end

    it "returns nil for a name not on PATH" do
      expect(described_class.which("definitely-not-a-real-binary-xyz", "/nonexistent")).to be_nil
    end
  end

  describe ".http_ok" do
    around do |example|
      @server = TCPServer.new("127.0.0.1", 0)
      @thread = Thread.new { serve }
      example.run
    ensure
      @thread&.kill
      @server.close
    end

    def serve
      loop do
        client = @server.accept
        client.gets
        client.print("HTTP/1.1 #{@status} Nope\r\nContent-Length: 0\r\n\r\n")
        client.close
      end
    end

    def url = "http://127.0.0.1:#{@server.addr[1]}/"

    it "is true for a 2xx response" do
      @status = 200
      expect(described_class.http_ok(url, timeout: 2)).to be true
    end

    it "is false for a non-2xx response" do
      @status = 500
      expect(described_class.http_ok(url, timeout: 2)).to be false
    end

    it "is false instead of raising when the connection fails" do
      expect(described_class.http_ok("http://127.0.0.1:1/", timeout: 1)).to be false
    end
  end

  describe ".descendants" do
    it "finds a process below the given pid" do
      expect(described_class.descendants(Process.ppid)).to include(Process.pid)
    end

    it "is empty for a pid nothing descends from" do
      expect(described_class.descendants(999_999)).to eq([])
    end

    it "does not list the pid itself" do
      expect(described_class.descendants(Process.pid)).not_to include(Process.pid)
    end
  end

  describe ".read_pid" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = Pathname.new(dir)
        example.run
      end
    end

    it "returns nil instead of raising when the pid file is a directory" do
      path = @dir / "llama-server.pid"
      path.mkpath

      expect(described_class.read_pid(path, "llama-server")).to be_nil
    end

    it "returns nil for a pid with no /proc entry" do
      path = @dir / "llama-server.pid"
      path.write("999999")

      expect(described_class.read_pid(path, "llama-server")).to be_nil
    end

    it "returns nil instead of raising when /proc denies the cmdline read" do
      path = @dir / "llama-server.pid"
      path.write("111")
      allow(Pathname).to receive(:new).and_call_original
      allow(Pathname).to receive(:new).with("/proc/111/cmdline").and_raise(Errno::EACCES)

      expect(described_class.read_pid(path, "llama-server")).to be_nil
    end

    it "returns nil instead of raising when the pid file is unreadable" do
      path = @dir / "llama-server.pid"
      path.write("123")
      path.chmod(0o000)

      expect(described_class.read_pid(path, "llama-server")).to be_nil
    end
  end
end
