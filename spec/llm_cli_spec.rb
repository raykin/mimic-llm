require_relative "../lib/mimic"
require_relative "../lib/mimic/llm_cli"
require "tmpdir"
require "fileutils"

RSpec.describe Mimic::LlmCli do
  subject(:cli) { described_class.new }

  def stub_config(port: 8080)
    settings = Mimic::LlmConfig::Settings.new("llama" => { "host" => "127.0.0.1", "port" => port })
    allow(Mimic::LlmConfig).to receive_messages(exists?: true, load: settings)
    settings
  end

  def stub_engine(result)
    allow(Mimic::Services::Engine).to receive(:for).and_return(instance_double(Mimic::Services::Llama, start: result))
  end

  describe "#start" do
    it "prints the engine's message and exits 0 when it started" do
      stub_config
      stub_engine(Mimic::Result.ok("ready"))

      expect { cli.start }.to output(/ready/).to_stdout
    end

    it "prints the failure and exits 1 when it did not" do
      stub_config
      stub_engine(Mimic::Result.error("boom"))

      expect do
        expect { cli.start }.to output(/boom/).to_stdout
      end.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end
  end

  describe "#restart" do
    before do
      allow(Mimic::Services::Llama).to receive(:stop).and_return(true)
      # One pass through the real released? predicate, without the 30 s poll.
      allow(Mimic::Probes).to receive(:wait_until) { |**_, &block| block.call }
    end

    it "starts again once no llama-server remains and the port is free" do
      stub_config
      stub_engine(Mimic::Result.ok("ready"))
      allow(Mimic::Probes).to receive(:find_pid_by_cmd).with("llama-server").and_return(nil)
      allow(Mimic::Probes).to receive(:port_free?).with("127.0.0.1", 8080).and_return(true)

      expect { cli.restart }.to output(/ready/).to_stdout
    end

    it "aborts while a matching process is still found" do
      stub_config
      stub_engine(Mimic::Result.ok("ready"))
      allow(Mimic::Probes).to receive(:find_pid_by_cmd).with("llama-server").and_return(123)

      expect do
        expect { cli.restart }.to output(/still holds 127\.0\.0\.1:8080 -- restart aborted/).to_stdout
      end.to raise_error(SystemExit)
      expect(Mimic::Services::Engine).not_to have_received(:for)
    end
  end
end
