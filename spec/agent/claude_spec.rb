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

    def launched_command(agent, args, version: [2, 1, 98])
      allow(described_class).to receive(:find_binary).and_return("/usr/bin/claude")
      allow(agent).to receive_messages(version: version, status_line: {}, extra_env: {})
      captured = nil
      allow(Mimic::Agent).to receive(:spawn_and_wait) do |command, _env|
        captured = command
        0
      end
      agent.launch(args)
      captured
    end

    it "pins the local env in the overlay and blanks provider routing, which user settings would otherwise restore" do
      command = launched_command(agent, [])

      env = JSON.parse(command[command.index("--settings") + 1])["env"]
      expect(env["ANTHROPIC_BASE_URL"]).to eq("http://x")
      expect(env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"]).to eq("8192")
      expect(env["CLAUDE_CODE_USE_BEDROCK"]).to eq("")
      expect(env).not_to have_key("CLAUDE_CONFIG_DIR")
    end

    it "still passes the overlay to a claude too old for the dynamic-sections flag" do
      command = launched_command(agent, [], version: [2, 1, 97])

      expect(command).to include("--settings")
      expect(command).not_to include(described_class::DYNAMIC_SECTIONS_FLAG)
    end

    it "blanks apiKeyHelper, which would send a user's cloud key to llama-server" do
      command = launched_command(agent, [])

      expect(JSON.parse(command[command.index("--settings") + 1])["apiKeyHelper"]).to eq("")
    end

    # Claude keeps only the last --settings, so a forwarded one passed on its own is dropped.
    it "merges a forwarded --settings into mimic's overlay, under mimic's own keys" do
      Dir.mktmpdir do |dir|
        file = Pathname.new(dir) / "mine.json"
        file.write(JSON.generate({ "model" => "x", "permissions" => { "allow" => ["Bash(ls)"] } }))
        inline = JSON.generate({ "env" => { "FOO" => "1", "ANTHROPIC_BASE_URL" => "https://cloud" }, "theme" => "dark" })

        command = launched_command(agent, ["--settings", file.to_s, "-p", "hi", "--settings=#{inline}", "--", "--settings=x"])

        expect(command.count("--settings")).to eq(1)
        expect(command.last(4)).to eq(["-p", "hi", "--", "--settings=x"])
        overlay = JSON.parse(command[command.index("--settings") + 1])
        expect(overlay).to include("theme" => "dark", "model" => "x", "availableModels" => ["my-model"])
        expect(overlay["env"]).to include("FOO" => "1", "ANTHROPIC_BASE_URL" => "http://x")
        expect(overlay["permissions"]).to include("allow" => ["Bash(ls)"], "deny" => %w[WebSearch WebFetch])
      end
    end

    it "keeps a forwarded --settings' own deny and ask lists beside mimic's" do
      user = JSON.generate({ "permissions" => { "deny" => ["Bash(rm *)", "WebFetch"], "ask" => ["Edit"] } })

      command = launched_command(agent, ["--settings", user])

      permissions = JSON.parse(command[command.index("--settings") + 1])["permissions"]
      expect(permissions["deny"]).to contain_exactly("Bash(rm *)", "WebSearch", "WebFetch")
      expect(permissions["ask"]).to contain_exactly("Edit", "Task", "Agent")
    end

    it "puts an unreadable forwarded --settings before mimic's, so mimic's overlay still applies" do
      command = launched_command(agent, ["--settings", "/nonexistent/mine.json", "-p", "hi"])

      expect(command.first(3)).to eq(["claude", "--settings", "/nonexistent/mine.json"])
      expect(command.count("--settings")).to eq(2)
      expect(JSON.parse(command[command.rindex("--settings") + 1])["availableModels"]).to eq(["my-model"])
    end

    it "keeps the old order when a forwarded --settings is JSON of the wrong shape" do
      command = launched_command(agent, ["--settings", JSON.generate({ "env" => "nope" })])

      expect(command.count("--settings")).to eq(2)
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

    it "sets the auto-compact window when a context length of at least 100k is known" do
      agent = described_class.new(settings_double(131_072))
      allow(described_class).to receive(:find_binary).and_return(nil)
      allow(agent).to receive(:extra_env).and_return({})

      env = agent.env

      expect(env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"]).to eq("131072")
      expect(env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"]).to eq("131072")
      expect(env["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"]).to eq("90")
      expect(env).not_to have_key("CLAUDE_CODE_MAX_OUTPUT_TOKENS")
    end

    it "blanks the auto-compact window below 100k, which claude ignores and warns about" do
      allow(described_class).to receive(:find_binary).and_return(nil)
      allow(agent).to receive(:extra_env).and_return({})

      env = agent.env

      expect(env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"]).to eq("")
      expect(env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"]).to eq("8192")
    end

    it "caps output at a quarter of a window under 80k, so compaction leaves room for the conversation" do
      allow(described_class).to receive(:find_binary).and_return(nil)
      allow(agent).to receive(:extra_env).and_return({})

      expect(agent.env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"]).to eq("2048")
    end

    it "leaves claude's own output cap alone from an 80k window up" do
      agent = described_class.new(settings_double(80_000))
      allow(described_class).to receive(:find_binary).and_return(nil)
      allow(agent).to receive(:extra_env).and_return({})

      expect(agent.env).not_to have_key("CLAUDE_CODE_MAX_OUTPUT_TOKENS")
    end

    it "turns off the token-countdown reminders and unsets provider routing" do
      allow(described_class).to receive(:find_binary).and_return(nil)
      allow(agent).to receive(:extra_env).and_return({})

      env = agent.env

      expect(env["CLAUDE_CODE_TOTAL_TOKENS_REMINDER"]).to eq("off")
      expect(env).to include("CLAUDE_CODE_USE_BEDROCK" => nil, "ANTHROPIC_UNIX_SOCKET" => nil)
    end

    it "omits the auto-compact window when context length is nil" do
      nil_settings = settings_double(nil)
      agent = described_class.new(nil_settings)
      allow(described_class).to receive(:find_binary).and_return(nil)
      allow(agent).to receive(:extra_env).and_return({})

      env = agent.env

      expect(env).not_to have_key("CLAUDE_CODE_AUTO_COMPACT_WINDOW")
      expect(env).not_to have_key("CLAUDE_CODE_MAX_CONTEXT_TOKENS")
    end

    it "disables the comment gate, whose judge call would evict the served model's prompt cache" do
      allow(described_class).to receive(:find_binary).and_return(nil)
      allow(agent).to receive(:ensure_config_dir).and_return(Pathname.new("/tmp/claude-config"))

      expect(agent.env["COMMENT_GATE_OFF"]).to eq("1")
    end

    # MCP servers are opt-in: mimic wires whatever ~/.mimic/mcp-servers.json
    # names and nothing at all when that file is absent.
    describe "MCP servers" do
      def seeded(dir, seed_data, servers: :none)
        config_dir = Pathname.new(dir) / "claude-config"
        config_dir.mkpath
        (config_dir / ".claude.json").write(JSON.generate(seed_data))
        stub_const("Mimic::Paths::CLAUDE_CONFIG_DIR", config_dir)
        servers_file = Pathname.new(dir) / "mcp-servers.json"
        servers_file.write(servers) unless servers == :none
        stub_const("Mimic::Paths::MCP_SERVERS_PATH", servers_file)
        allow(described_class).to receive(:find_binary).and_return(nil)
        config_dir / ".claude.json"
      end

      let(:c4ai) { { "command" => "python", "args" => ["-m", "c4ai_mcp.fastmcp_server"] } }

      it "wires nothing when no mcp-servers.json exists" do
        Dir.mktmpdir do |dir|
          seed = seeded(dir, {})

          agent.env

          expect(JSON.parse(seed.read)).not_to have_key("mcpServers")
        end
      end

      it "merges every server the file names into an empty seed" do
        Dir.mktmpdir do |dir|
          seed = seeded(dir, {}, servers: JSON.generate({ "c4ai" => c4ai, "other" => { "command" => "srv" } }))

          agent.env

          servers = JSON.parse(seed.read)["mcpServers"]
          expect(servers["c4ai"]).to eq(c4ai)
          expect(servers["other"]).to eq({ "command" => "srv" })
        end
      end

      it "preserves Claude Code's own runtime state alongside the merge" do
        Dir.mktmpdir do |dir|
          seed = seeded(dir, { "hasCompletedOnboarding" => true, "numStartups" => 7 },
                        servers: JSON.generate({ "c4ai" => c4ai }))

          agent.env

          data = JSON.parse(seed.read)
          expect(data["numStartups"]).to eq(7)
          expect(data["hasCompletedOnboarding"]).to be true
          expect(data["mcpServers"]["c4ai"]).to eq(c4ai)
        end
      end

      # A server the user added by hand in Claude Code stays put.
      it "leaves entries it does not own alone" do
        Dir.mktmpdir do |dir|
          seed = seeded(dir, { "mcpServers" => { "mine" => { "command" => "hand-rolled" } } },
                        servers: JSON.generate({ "c4ai" => c4ai }))

          agent.env

          expect(JSON.parse(seed.read)["mcpServers"]["mine"]).to eq({ "command" => "hand-rolled" })
        end
      end

      it "does not rewrite the file when every named server is already current" do
        Dir.mktmpdir do |dir|
          seed = seeded(dir, { "mcpServers" => { "c4ai" => c4ai } }, servers: JSON.generate({ "c4ai" => c4ai }))

          expect { agent.env }.not_to(change { seed.mtime })
        end
      end

      it "wires nothing when mcp-servers.json is not valid JSON" do
        Dir.mktmpdir do |dir|
          seed = seeded(dir, {}, servers: "{ not json")

          agent.env

          expect(JSON.parse(seed.read)).not_to have_key("mcpServers")
        end
      end
    end
  end
end
