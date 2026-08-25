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
        example.run
      end
    end

    # Regression: both engines spawn with pgroup: true specifically so the
    # router's grandchild model process shares the parent's process group.
    # Sending TERM to the bare pid only kills the router, leaving the
    # VRAM-holding grandchild running and orphaned.
    it "signals the process group, not only the recorded pid" do
      pid_file = @dir / "llama-server.pid"
      pid_file.write("555")
      allow(described_class).to receive(:read_pid).and_return(555)
      allow(Process).to receive(:getpgid).with(555).and_return(555)

      expect(Process).to receive(:kill).with("TERM", -555)

      described_class.stop_pid(pid_file, "llama-server")
    end

    # The /proc fallback hands back whatever pid matched, which need not lead
    # a group. `kill(-pid)` then raises ESRCH out of `llm stop` and the server
    # keeps running -- exactly the case the fallback exists to handle.
    it "signals the bare pid when the process is not a group leader" do
      pid_file = @dir / "absent.pid"
      allow(described_class).to receive(:read_pid).and_return(nil)
      allow(described_class).to receive(:find_pid_by_cmd).and_return(556)
      allow(Process).to receive(:getpgid).with(556).and_return(400)

      expect(Process).to receive(:kill).with("TERM", 556)

      expect(described_class.stop_pid(pid_file, "llama-server")).to be true
    end

    it "signals the bare pid when the group cannot be determined" do
      pid_file = @dir / "absent.pid"
      allow(described_class).to receive(:read_pid).and_return(nil)
      allow(described_class).to receive(:find_pid_by_cmd).and_return(557)
      allow(Process).to receive(:getpgid).and_raise(Errno::ESRCH)

      expect(Process).to receive(:kill).with("TERM", 557)

      described_class.stop_pid(pid_file, "llama-server")
    end

    # Both servers are the same binary, so the /proc fallback cannot tell
    # them apart on argv[0] alone -- stopping the chat server must not take
    # the embedding server with it.
    it "skips excluded pids in the fallback scan" do
      pid_file = @dir / "absent.pid"
      allow(described_class).to receive(:read_pid).and_return(nil)
      allow(described_class).to receive(:find_pid_by_cmd).with("llama-server", exclude: [900]).and_return(nil)

      expect(Process).not_to receive(:kill)

      expect(described_class.stop_pid(pid_file, "llama-server", exclude: [900])).to be false
    end

    it "does not scan /proc at all when the fallback is off" do
      pid_file = @dir / "absent.pid"
      allow(described_class).to receive(:read_pid).and_return(nil)

      expect(described_class).not_to receive(:find_pid_by_cmd)

      expect(described_class.stop_pid(pid_file, "llama-server", fallback: false)).to be false
    end

    it "returns false and leaves no pid file when no matching process is found" do
      pid_file = @dir / "llama-server.pid"
      pid_file.write("555")
      allow(described_class).to receive(:read_pid).and_return(nil)
      allow(described_class).to receive(:find_pid_by_cmd).and_return(nil)

      expect(described_class.stop_pid(pid_file, "llama-server")).to be false
      expect(pid_file).not_to exist
    end
  end

  describe ".port_free?" do
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

    it "is nil for a 404 that still returns a JSON body" do
      @status = 404
      expect(described_class.http_json(url, timeout: 2)).to be_nil
    end

    it "returns the parsed body on success" do
      @status = 200
      expect(described_class.http_json(url, timeout: 2)).to eq({ "error" => "boom" })
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

  describe ".argv0" do
    it "returns nil for a pid whose /proc entry doesn't exist" do
      expect(described_class.argv0(999_999)).to be_nil
    end

    it "returns nil instead of raising when /proc denies the read" do
      allow(Pathname).to receive(:new).and_call_original
      allow(Pathname).to receive(:new).with("/proc/111/cmdline").and_raise(Errno::EACCES)

      expect(described_class.argv0(111)).to be_nil
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

    it "returns nil instead of raising when the pid file is unreadable" do
      path = @dir / "llama-server.pid"
      path.write("123")
      path.chmod(0o000)

      expect(described_class.read_pid(path, "llama-server")).to be_nil
    end
  end
end
