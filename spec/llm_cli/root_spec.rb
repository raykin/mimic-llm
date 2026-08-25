require_relative "../../lib/mimic"
require_relative "../../lib/mimic/llm_cli"
require "tmpdir"
require "fileutils"

RSpec.describe Mimic::LlmCli::Root do
  subject(:cli) { described_class.new }

  def stub_config(port: 8080)
    settings = Mimic::LlmConfig::Settings.new("llama" => { "host" => "127.0.0.1", "port" => port })
    allow(Mimic::LlmConfig).to receive_messages(exists?: true, load: settings)
    settings
  end

  def stub_engine(result)
    allow(Mimic::EngineCli::Registry).to receive(:for).and_return(instance_double(Mimic::Engine::Llama, start: result))
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

  # The preset is one file shared by every model, so the record a previous
  # model settled on has to be cleared before the preset is written, not
  # after. Order is the whole guarantee; both calls firing is not enough.
  describe "#setup" do
    def stub_wizard(settings)
      wizard = instance_double(Mimic::LlmCli::Wizard::Setup, config: settings)
      %i[system_check choose_model choose_mmproj choose_context choose_reasoning].each do |step|
        allow(wizard).to receive(step)
      end
      allow(wizard).to receive_messages(choose_engine: "llama.cpp", ensure_binary: nil)
      allow(Mimic::LlmCli::Wizard::Setup).to receive(:new).and_return(wizard)
      wizard
    end

    it "clears the remembered sampling before it renders the preset" do
      allow(Mimic::Ui::Prompt).to receive(:new).and_return(instance_double(Mimic::Ui::Prompt, yes?: false))
      order = []
      settings = Mimic::LlmConfig::Settings.new("model" => {}, "llama" => {})
      allow(settings).to receive(:save)
      allow(settings).to receive(:forget_sampling) { order << :forget }
      allow(Mimic::LlmConfig).to receive(:load).and_return(settings)
      stub_wizard(settings)
      engine = instance_double(Mimic::Engine::Llama)
      allow(engine).to receive(:render_preset) { order << :render }
      allow(Mimic::EngineCli::Registry).to receive(:for).and_return(engine)
      allow(Mimic::Clients).to receive(:sync).and_return([])

      expect { cli.setup }.to output.to_stdout
      expect(order).to eq(%i[forget render])
    end
  end

  describe "#restart" do
    before do
      allow(Mimic::Engine::Base).to receive(:stop).and_return(true)
      allow(Mimic::Engine::LlamaEmbed).to receive(:pids).and_return([])
      # One pass through the real released? predicate, without the 30 s poll.
      allow(Mimic::Util::Probes).to receive(:wait_until) { |**_, &block| block.call }
    end

    it "starts again once no llama-server remains and the port is free" do
      stub_config
      stub_engine(Mimic::Result.ok("ready"))
      allow(Mimic::Util::Probes).to receive(:find_pid_by_cmd).with("llama-server", exclude: []).and_return(nil)
      allow(Mimic::Util::Probes).to receive(:port_free?).with("127.0.0.1", 8080).and_return(true)

      expect { cli.restart }.to output(/ready/).to_stdout
    end

    it "aborts while a matching process is still found" do
      stub_config
      stub_engine(Mimic::Result.ok("ready"))
      allow(Mimic::Util::Probes).to receive(:find_pid_by_cmd).with("llama-server", exclude: []).and_return(123)

      expect do
        expect { cli.restart }.to output(/still holds 127\.0\.0\.1:8080 -- restart aborted/).to_stdout
      end.to raise_error(SystemExit)
      expect(Mimic::EngineCli::Registry).not_to have_received(:for)
    end
  end
end
