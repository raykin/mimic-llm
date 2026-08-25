require_relative "../../lib/mimic"
require "tmpdir"

RSpec.describe Mimic::Engine::Launcher do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  def launcher(log: @dir / "server.log", pid_file: @dir / "run/server.pid")
    described_class.new(log_file: log, pid_file: pid_file, chdir: @dir)
  end

  describe "#spawn" do
    it "records the pid of the spawned process" do
      pid_file = @dir / "run/server.pid"
      allow(Process).to receive(:spawn).and_return(4242)

      expect(launcher(pid_file: pid_file).spawn(["/bin/llama-server", "-m", "/m.gguf"])).to eq(4242)
      expect(pid_file.read).to eq("4242")
    end

    # The server outlives the CLI that started it, so it has to be in its own
    # process group -- otherwise a Ctrl-C in the launching shell kills it.
    it "spawns detached into its own process group, appending to the log" do
      log = @dir / "server.log"
      log.write("earlier run\n")
      allow(Process).to receive(:spawn).and_return(1)

      launcher(log: log).spawn(["/bin/llama-server"])

      expect(Process).to have_received(:spawn).with(
        "/bin/llama-server", hash_including(chdir: @dir.to_s, pgroup: true)
      )
      expect(log.read).to eq("earlier run\n")
    end

    it "closes the log handle when the spawn raises" do
      log = @dir / "server.log"
      opened = nil
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with(log, "ab") { opened = File.new(log, "ab") }
      allow(Process).to receive(:spawn).and_raise(Errno::ENOENT)

      expect { launcher(log: log).spawn(["/bin/llama-server"]) }.to raise_error(Errno::ENOENT)
      expect(opened).to be_closed
    end

    it "creates the pid directory when it does not exist yet" do
      pid_file = @dir / "missing/server.pid"
      allow(Process).to receive(:spawn).and_return(7)

      launcher(pid_file: pid_file).spawn(["/bin/llama-server"])

      expect(pid_file).to exist
    end
  end
end
