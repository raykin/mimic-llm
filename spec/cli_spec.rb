require_relative "../lib/mimic"
require_relative "../lib/mimic/cli"
require_relative "../lib/mimic/agent"

RSpec.describe Mimic::Cli do
  let(:cfg) { instance_double(Mimic::LlmConfig::Settings) }

  before do
    allow(Mimic::LlmConfig).to receive_messages(exists?: true, load: cfg)
    allow(Mimic::Engine::Llama).to receive(:new).with(cfg).and_return(instance_double(Mimic::Engine::Llama, running?: true))
  end

  def run(argv) = described_class.new(argv).run

  HELP = <<~HELP.freeze
    usage: mimic [command] [args...]

    Local Hermes + Claude Code stack

    commands:
      verify         check installs, running services and recent errors
      install-hermes install hermes-agent into ~/.hermes/venv
      hermes-lcc     Hermes -> claude-code skill -> Claude Code -> llama.cpp
      claude         Claude Code -> llama.cpp via Unsloth's start recipe
      codex          Codex -> llama.cpp via Unsloth's config recipe

    (no command)    interactive menu
  HELP

  describe "help" do
    it "prints the command list verbatim for -h and --help" do
      expect { run(["-h"]) }.to output(HELP).to_stdout
      expect { run(["--help"]) }.to output(HELP).to_stdout
    end

    it "prints the same help after the error line for an unknown command" do
      expect { expect { run(["nope"]) }.to raise_error(SystemExit) }
        .to output(HELP).to_stdout.and output("unknown command: nope\n").to_stderr
    end
  end

  describe "dispatch" do
    it "runs the health check for verify" do
      allow(Mimic::Health).to receive(:run).with(cfg).and_return(true)

      run(["verify"])

      expect(Mimic::Health).to have_received(:run).with(cfg)
    end

    it "exits non-zero when the health check fails" do
      allow(Mimic::Health).to receive(:run).and_return(false)

      expect { run(["verify"]) }.to raise_error(SystemExit)
    end

    it "reports an already-installed hermes instead of prompting" do
      allow(Mimic::Agent::Hermes).to receive(:find_binary).and_return("/usr/bin/hermes")

      expect { run(["install-hermes"]) }.to output(/hermes found.*usr.bin.hermes/).to_stdout
    end

    it "installs hermes when the user agrees" do
      allow(Mimic::Agent::Hermes).to receive_messages(find_binary: nil, install: "/venv/bin/hermes")
      allow(Mimic::Ui::Prompt).to receive(:new).and_return(instance_double(Mimic::Ui::Prompt, yes?: true))

      expect { run(["install-hermes"]) }.to output(%r{hermes installed.*/venv/bin/hermes}).to_stdout
      expect(Mimic::Agent::Hermes).to have_received(:install)
    end

    it "skips the install when the user declines" do
      allow(Mimic::Agent::Hermes).to receive_messages(find_binary: nil, install: "/venv/bin/hermes")
      allow(Mimic::Ui::Prompt).to receive(:new).and_return(instance_double(Mimic::Ui::Prompt, yes?: false))

      expect { run(["install-hermes"]) }.to output(/Skipping Hermes/).to_stdout
      expect(Mimic::Agent::Hermes).not_to have_received(:install)
    end

    it "passes the remaining argv through to hermes-lcc" do
      allow(Mimic::Agent::Hermes).to receive(:launch)

      run(["hermes-lcc", "--verbose", "-p", "hi"])

      expect(Mimic::Agent::Hermes).to have_received(:launch).with(cfg, ["--verbose", "-p", "hi"])
    end

    { "claude" => Mimic::Agent::Claude, "codex" => Mimic::Agent::Codex }.each do |command, agent|
      it "passes the remaining argv through to #{command}" do
        launcher = instance_double(agent, launch: nil)
        allow(agent).to receive(:new).with(cfg).and_return(launcher)

        run([command, "--model", "x"])

        expect(launcher).to have_received(:launch).with(["--model", "x"])
      end
    end
  end

  describe "guards" do
    it "aborts every config-taking command when no LLM config exists" do
      allow(Mimic::LlmConfig).to receive(:exists?).and_return(false)

      %w[verify hermes-lcc claude codex].each do |command|
        expect { run([command]) }.to raise_error(SystemExit).and output(/no LLM config yet/).to_stderr
      end
    end

    it "refuses to launch an agent while llama-server is down" do
      allow(Mimic::Engine::Llama).to receive(:new).and_return(instance_double(Mimic::Engine::Llama, running?: false))
      allow(Mimic::Agent::Hermes).to receive(:launch)

      expect { expect { run(["hermes-lcc"]) }.to raise_error(SystemExit) }
        .to output(/`mimic hermes-lcc` requires llama-server to be running/).to_stdout
      expect(Mimic::Agent::Hermes).not_to have_received(:launch)
    end
  end

  describe "the menu" do
    let(:labels) do
      [
        "Launch Hermes + Claude Code bridge (claude-code skill direct to llama.cpp)",
        "Launch Claude Code -- direct to llama.cpp (Unsloth start recipe)",
        "Launch Codex -- direct to llama.cpp (Unsloth config recipe)",
        "Verify stack (installs, services, errors)",
        "Install hermes-agent into an isolated venv",
      ]
    end

    def prompt_picking(label)
      instance_double(Mimic::Ui::Prompt).tap { |p| allow(p).to receive(:select).and_return(label) }
    end

    it "offers every command, in launch-first order" do
      prompt = prompt_picking(labels.first)
      allow(Mimic::Ui::Prompt).to receive(:new).and_return(prompt)
      allow(Mimic::Agent::Hermes).to receive(:launch)

      described_class.new([]).menu

      expect(prompt).to have_received(:select).with("mimic-llm:", labels)
    end

    it "dispatches the picked label with no pass-through args" do
      allow(Mimic::Ui::Prompt).to receive(:new).and_return(prompt_picking(labels[3]))
      allow(Mimic::Health).to receive(:run).and_return(true)

      described_class.new([]).menu

      expect(Mimic::Health).to have_received(:run).with(cfg)
    end

    it "reaches the menu when run gets no command at all" do
      allow(Mimic::Ui::Prompt).to receive(:new).and_return(prompt_picking(labels[3]))
      allow(Mimic::Health).to receive(:run).and_return(true)

      run([])

      expect(Mimic::Health).to have_received(:run)
    end

    it "returns nil instead of raising when the prompt is interrupted" do
      prompt = instance_double(Mimic::Ui::Prompt)
      allow(Mimic::Ui::Prompt).to receive(:new).and_return(prompt)
      allow(prompt).to receive(:select).and_raise(Interrupt)

      expect(described_class.new([]).menu).to be_nil
    end
  end
end
