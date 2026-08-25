require_relative "../../lib/mimic"
require_relative "../../lib/mimic/agent"
require "tmpdir"

RSpec.describe Mimic::Agent::Claude do
  def settings_double(context_length)
    instance_double(
      Mimic::LlmConfig::Settings,
      model: instance_double(Mimic::LlmConfig::ModelSettings, name: "my-model", context_length: context_length),
      llama: instance_double(Mimic::LlmConfig::LlamaSettings, base_url: "http://x"),
    )
  end

  let(:settings) { settings_double(8192) }
  subject(:agent) { described_class.new(settings) }

  describe "#launch" do
    it "exits non-zero with a message when claude isn't installed" do
      allow(described_class).to receive(:find_binary).and_return(nil)
      expect do
        expect { agent.launch([]) }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end.to output(/claude binary not found/).to_stderr
    end

    it "puts --model first and appends extra args" do
      allow(described_class).to receive(:find_binary).and_return("/usr/bin/claude")
      allow(agent).to receive_messages(flags: [], extra_env: {})
      allow(Mimic::Agent).to receive(:spawn_and_wait).and_return(0)

      agent.launch(["--continue"])

      expect(Mimic::Agent).to have_received(:spawn_and_wait)
        .with(["claude", "--model", "my-model", "--continue"], anything)
    end

    it "raises the child's exit status when it fails" do
      allow(described_class).to receive(:find_binary).and_return("/usr/bin/claude")
      allow(agent).to receive_messages(flags: [], extra_env: {})
      allow(Mimic::Agent).to receive(:spawn_and_wait).and_return(7)

      expect { agent.launch([]) }.to raise_error(SystemExit) { |e| expect(e.status).to eq(7) }
    end

    it "denies WebSearch and WebFetch in the settings overlay, dead against the local llama.cpp bridge" do
      allow(described_class).to receive(:find_binary).and_return("/usr/bin/claude")
      allow(agent).to receive_messages(version: [2, 1, 98], status_line: {}, extra_env: {})
      captured = nil
      allow(Mimic::Agent).to receive(:spawn_and_wait) do |command, _env|
        captured = command
        0
      end

      agent.launch([])

      overlay = JSON.parse(captured[captured.index("--settings") + 1])
      expect(overlay["permissions"]["deny"]).to eq(%w[WebSearch WebFetch])
    end
  end

  describe "#env" do
    it "re-applies the model pin through the shim, not just the env" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        real_claude = root / "claude"
        real_claude.write("#!/bin/sh\n")
        real_claude.chmod(0o755)
        stub_const("Mimic::Agent::Claude::SHIM_DIR", root / "bin")
        allow(described_class).to receive(:find_binary).and_return(real_claude.to_s)
        allow(agent).to receive_messages(flags: ["--settings", "{}"], extra_env: {})

        agent.env

        flags = JSON.parse((root / "bin" / "claude").read[/^FLAGS = (.*)$/, 1])
        expect(flags).to eq(["--model", "my-model", "--settings", "{}"])
      end
    end

    it "sets the auto-compact window when a context length is known" do
      allow(described_class).to receive(:find_binary).and_return(nil)
      allow(agent).to receive(:extra_env).and_return({})

      env = agent.env

      expect(env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"]).to eq("8192")
      expect(env["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"]).to eq("90")
    end

    it "omits the auto-compact window when context length is nil" do
      nil_settings = settings_double(nil)
      agent = described_class.new(nil_settings)
      allow(described_class).to receive(:find_binary).and_return(nil)
      allow(agent).to receive(:extra_env).and_return({})

      env = agent.env

      expect(env).not_to have_key("CLAUDE_CODE_AUTO_COMPACT_WINDOW")
    end

    it "disables the comment gate, whose judge call would evict the served model's prompt cache" do
      allow(described_class).to receive(:find_binary).and_return(nil)
      allow(described_class).to receive(:ensure_config_dir).and_return(Pathname.new("/tmp/claude-config"))

      expect(agent.env["COMMENT_GATE_OFF"]).to eq("1")
    end

    it "adds the c4ai server to an empty seed" do
      Dir.mktmpdir do |dir|
        config_dir = Pathname.new(dir) / "claude-config"
        config_dir.mkpath
        (config_dir / ".claude.json").write(JSON.generate({}))
        stub_const("Mimic::Paths::CLAUDE_CONFIG_DIR", config_dir)
        allow(described_class).to receive(:find_binary).and_return(nil)

        agent.env

        data = JSON.parse((config_dir / ".claude.json").read)
        expect(data["mcpServers"]["c4ai"]).to eq(described_class::C4AI_MCP_SERVER)
      end
    end

    it "preserves Claude Code's own runtime state alongside the merge" do
      Dir.mktmpdir do |dir|
        config_dir = Pathname.new(dir) / "claude-config"
        config_dir.mkpath
        (config_dir / ".claude.json").write(JSON.generate({ "hasCompletedOnboarding" => true, "numStartups" => 7 }))
        stub_const("Mimic::Paths::CLAUDE_CONFIG_DIR", config_dir)
        allow(described_class).to receive(:find_binary).and_return(nil)

        agent.env

        data = JSON.parse((config_dir / ".claude.json").read)
        expect(data["numStartups"]).to eq(7)
        expect(data["hasCompletedOnboarding"]).to be true
        expect(data["mcpServers"]["c4ai"]).to eq(described_class::C4AI_MCP_SERVER)
      end
    end

    it "does not rewrite the file when the entry is already current" do
      Dir.mktmpdir do |dir|
        config_dir = Pathname.new(dir) / "claude-config"
        config_dir.mkpath
        seed = config_dir / ".claude.json"
        seed.write(JSON.generate({ "mcpServers" => { "c4ai" => described_class::C4AI_MCP_SERVER } }))
        stub_const("Mimic::Paths::CLAUDE_CONFIG_DIR", config_dir)
        allow(described_class).to receive(:find_binary).and_return(nil)

        expect { agent.env }.not_to(change { seed.mtime })
      end
    end
  end
end
