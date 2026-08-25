require_relative "../../lib/mimic"
require "tmpdir"

RSpec.describe Mimic::Engine::ServerProcess do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  def process(fallback: true)
    described_class.new(pid_file: @dir / "server.pid", log_file: @dir / "server.log",
                        proc_scan_fallback: fallback)
  end

  describe ".chat and .embed" do
    it "name two different servers" do
      expect(described_class.chat.pid_file).not_to eq(described_class.embed.pid_file)
      expect(described_class.chat.log_file).not_to eq(described_class.embed.log_file)
    end

    # The /proc scan matches "llama-server", which both servers are, so only
    # the chat side may fall back to it.
    it "allows the /proc fallback for the chat server only" do
      expect(described_class.chat.proc_scan_fallback?).to be true
      expect(described_class.embed.proc_scan_fallback?).to be false
    end
  end

  describe "#log_tail" do
    it "reads from an offset" do
      (@dir / "server.log").write("prelude\nready\n")

      expect(process.log_tail("prelude\n".bytesize)).to eq("ready\n")
    end

    it "scrubs invalid bytes" do
      (@dir / "server.log").binwrite("prelude\n\xFF\xFE junk\nline one\n")

      tail = process.log_tail("prelude\n".bytesize)
      expect(tail).to be_valid_encoding
      expect(tail).to include("line one")
      expect(tail).not_to include("prelude")
    end

    it "is empty when the log is missing" do
      expect(process.log_tail).to eq("")
    end

    it "keeps only the last LOG_TAIL_BYTES" do
      (@dir / "server.log").write("#{'x' * described_class::LOG_TAIL_BYTES}tail")

      expect(process.log_tail.bytesize).to eq(described_class::LOG_TAIL_BYTES)
      expect(process.log_tail).to end_with("tail")
    end
  end

  describe "#last_lines" do
    it "returns the final n lines" do
      expect(process.last_lines("a\nb\nc\nd\ne\n", 2)).to eq("d\ne")
    end
  end

  describe "#pid" do
    it "reads the recorded pid" do
      (@dir / "server.pid").write("4242\n")

      expect(process.pid).to eq("4242")
    end

    it "is nil when no pid file exists" do
      expect(process.pid).to be_nil
    end
  end

  describe "#pids" do
    it "is the recorded pid plus its descendants" do
      allow(Mimic::Util::Probes).to receive(:read_pid).and_return(500)
      allow(Mimic::Util::Probes).to receive(:descendants).with(500).and_return([501, 502])

      expect(process.pids).to eq([500, 501, 502])
    end

    it "is empty when the server is not running" do
      allow(Mimic::Util::Probes).to receive(:read_pid).and_return(nil)

      expect(process.pids).to eq([])
    end
  end

  describe "#stop" do
    it "passes its own pid file and fallback rule through" do
      allow(Mimic::Util::Probes).to receive(:stop_pid).and_return(true)

      process(fallback: false).stop(exclude: [7])

      expect(Mimic::Util::Probes).to have_received(:stop_pid)
        .with(@dir / "server.pid", "llama-server", exclude: [7], fallback: false)
    end
  end

  describe "#cleanup_failed" do
    # Regression: both engines are spawned with pgroup: true because router
    # mode's real model process is a grandchild the router respawns -- but
    # cleanup only signals the direct pid, leaving the grandchild (and its
    # VRAM) orphaned.
    it "signals the process group, not only the direct pid" do
      allow(Mimic::Util::Probes).to receive(:child_alive?).with(4242).and_return(true)
      allow(Process).to receive(:waitpid)

      expect(Process).to receive(:kill).with("TERM", -4242)

      process.cleanup_failed(4242)
    end

    it "unlinks its own pid file" do
      (@dir / "server.pid").write("4242")
      allow(Mimic::Util::Probes).to receive(:child_alive?).and_return(false)

      process.cleanup_failed(4242)

      expect(@dir / "server.pid").not_to exist
    end
  end
end
