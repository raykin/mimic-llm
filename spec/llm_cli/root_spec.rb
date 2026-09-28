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

  # Ctrl-C is the only way out of a cli-ui selection, and Thor has no handler
  # for the Interrupt it raises -- without one the documented exit prints a
  # backtrace through thor/dispatch.
  describe ".start" do
    it "reports the cancellation instead of a backtrace when interrupted" do
      allow(described_class).to receive(:dispatch).and_raise(Interrupt)

      expect { described_class.start(["setup"]) }.to raise_error(SystemExit)
        .and output(/cancelled/).to_stderr
    end

    it "exits 130, the conventional status for an interrupt" do
      allow(described_class).to receive(:dispatch).and_raise(Interrupt)

      expect { described_class.start(["setup"]) }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(130) }
    end

    it "keeps the development switch diagnostic callable but out of root help" do
      expect { described_class.start(["-h"]) }.not_to output(/debug SUBCOMMAND/).to_stdout
      expect { described_class.start(["debug", "help", "switch"]) }
        .to output(/Usage:\s+\S+ debug switch/).to_stdout
    end
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
      allow(Mimic::Client).to receive(:sync).and_return([])

      expect { cli.setup }.to output.to_stdout
      expect(order).to eq(%i[forget render])
    end
  end

  # Renamed from `benchmark` 2026-08-18: the command sizes concurrent request
  # slots so several tasks can run at once, which a benchmark is not.
  describe "#parallel" do
    subject(:cli) { described_class.new([], options) }

    before do
      allow(Mimic::Engine::ServerProcess).to receive_messages(
        chat: instance_double(Mimic::Engine::ServerProcess, stop: true),
        embed: instance_double(Mimic::Engine::ServerProcess, pids: []),
      )
      allow(Mimic::Util::Probes).to receive(:wait_until).and_return(true)
    end

    context "with slot and context overrides" do
      let(:options) { { slots: 4, ctx: 2048 } }

      it "applies them to this run only" do
        settings = stub_config
        engine = instance_double(Mimic::Engine::Llama, start: Mimic::Result.ok("ready"))
        allow(Mimic::EngineCli::Registry).to receive(:for).and_return(engine)
        # Stubbed even though this path must not reach it: unstubbed, a
        # regression here opens the real cli-ui wizard and the run blocks on
        # a prompt instead of failing.
        allow(Mimic::LlmCli::Wizard::Parallel).to receive(:new)

        expect { cli.parallel }.to output(/ready/).to_stdout
        expect(engine).to have_received(:start).with(remember: false)
        expect(settings.llama.n_slots).to eq(4)
        expect(settings.model.context_length).to eq(2048)
      end

      it "does not open the wizard" do
        stub_config
        allow(Mimic::EngineCli::Registry).to receive(:for)
          .and_return(instance_double(Mimic::Engine::Llama, start: Mimic::Result.ok("ready")))
        allow(Mimic::LlmCli::Wizard::Parallel).to receive(:new)

        expect { cli.parallel }.to output(/ready/).to_stdout
        expect(Mimic::LlmCli::Wizard::Parallel).not_to have_received(:new)
      end
    end

    context "with neither override" do
      let(:options) { {} }

      it "asks the wizard for the slot and context pair" do
        settings = stub_config
        wizard = instance_double(Mimic::LlmCli::Wizard::Parallel, run: settings)
        allow(Mimic::LlmCli::Wizard::Parallel).to receive(:new).and_return(wizard)
        allow(Mimic::EngineCli::Registry).to receive(:for)
          .and_return(instance_double(Mimic::Engine::Llama, start: Mimic::Result.ok("ready")))

        expect { cli.parallel }.to output(/ready/).to_stdout
        expect(wizard).to have_received(:run)
      end
    end
  end

  describe "#stop" do
    # The chat server may fall back to a /proc scan for "llama-server", which
    # the embedding server also is -- so its pids are excluded by name.
    it "stops the chat server while leaving the embedding server's pids alone" do
      chat = instance_double(Mimic::Engine::ServerProcess, stop: true)
      allow(Mimic::Engine::ServerProcess).to receive_messages(
        chat: chat, embed: instance_double(Mimic::Engine::ServerProcess, pids: [900, 901]),
      )

      expect { cli.stop }.to output("llama-server: stopped\n").to_stdout
      expect(chat).to have_received(:stop).with(exclude: [900, 901])
    end

    it "says so when nothing was running" do
      allow(Mimic::Engine::ServerProcess).to receive_messages(
        chat: instance_double(Mimic::Engine::ServerProcess, stop: false),
        embed: instance_double(Mimic::Engine::ServerProcess, pids: []),
      )

      expect { cli.stop }.to output("llama-server: was not running\n").to_stdout
    end
  end

  describe "#restart" do
    before do
      allow(Mimic::Engine::ServerProcess).to receive_messages(
        chat: instance_double(Mimic::Engine::ServerProcess, stop: true),
        embed: instance_double(Mimic::Engine::ServerProcess, pids: []),
      )
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
