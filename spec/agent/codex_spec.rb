require_relative "../../lib/mimic"
require_relative "../../lib/mimic/agent"
require "tmpdir"

RSpec.describe Mimic::Agent::Codex do
  def settings_double(context_length)
    instance_double(
      Mimic::LlmConfig::Settings,
      model: instance_double(Mimic::LlmConfig::ModelSettings, name: "m", context_length: context_length),
      llama: instance_double(Mimic::LlmConfig::LlamaSettings, base_url: "http://x"),
    )
  end

  let(:settings) { settings_double(4096) }
  subject(:agent) { described_class.new(settings) }
  let(:home) { @agents_dir / "codex" }

  around do |example|
    Dir.mktmpdir do |agents_root|
      Dir.mktmpdir do |user_home|
        @agents_dir = Pathname.new(agents_root)
        @user_home = Pathname.new(user_home)
        example.run
      end
    end
  end

  before do
    stub_const("Mimic::Paths::AGENTS_DIR", @agents_dir)
    allow(Dir).to receive(:home).and_return(@user_home.to_s)
    allow(Mimic::Util::Probes).to receive(:which).with("codex").and_return("/usr/bin/codex")
    allow(Open3).to receive(:capture2).and_return(["0.120.0\n", instance_double(Process::Status, success?: true)])
    allow(Mimic::Agent).to receive(:spawn_and_wait).and_return(0)
  end

  describe "#launch" do
    it "aborts when codex isn't installed and install isn't allowed" do
      allow(Mimic::Util::Probes).to receive(:which).with("codex").and_return(nil)
      expect do
        expect { agent.launch([]) }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end.to output(/codex binary not found/).to_stderr
    end

    it "writes a config.toml with the oss_provider wiring on an empty home" do
      agent.launch([])

      config = (home / "config.toml").read
      expect(config).to include("oss_provider = \"unsloth_api\"")
      expect(config.scan("[model_providers.unsloth_api]").length).to eq(1)
      expect(config).to include("http://x/v1")
    end

    it "does not duplicate the provider wiring across launches" do
      agent.launch([])
      agent.launch([])

      config = (home / "config.toml").read
      expect(config.scan("oss_provider").length).to eq(1)
      expect(config.scan("[model_providers.unsloth_api]").length).to eq(1)
    end

    it "seeds from the user's own codex config once, stripping managed keys and stale provider tables" do
      (@user_home / ".codex").mkpath
      (@user_home / ".codex" / "config.toml").write(<<~TOML)
        oss_provider = "old"
        model = "old-model"
        keep_this = true

        [model_providers.unsloth_api]
        name = "old"

        [mcp_servers.foo]
        command = "bar"
      TOML

      agent.launch([])

      config = (home / "config.toml").read
      expect(config).to include("keep_this = true")
      expect(config).to include("[mcp_servers.foo]")
      expect(config.scan("[model_providers.unsloth_api]").length).to eq(1)
      expect(config).not_to include("\"old\"")
      expect(config).not_to include("old-model")
    end

    it "does not reseed the agent home on a second launch" do
      agent.launch([])
      (home / "config.toml").write("untouched\n")

      agent.launch([])

      expect((home / "config.toml").read).to include("untouched")
    end

    it "writes model catalog fields only when the context length is known" do
      agent.launch([])

      catalog = JSON.parse((home / "model-catalog.json").read)
      entry = catalog["models"].first
      expect(entry["context_window"]).to eq(4096)
      expect(entry["max_context_window"]).to eq(4096)
    end

    it "omits model catalog context window fields when context_length is nil" do
      nil_settings = settings_double(nil)

      described_class.new(nil_settings).launch([])

      catalog = JSON.parse((home / "model-catalog.json").read)
      entry = catalog["models"].first
      expect(entry).not_to have_key("context_window")
    end
  end

  describe "FALLBACK_PROMPT" do
    it "resolves beside this module, not the old lib/mimic root" do
      expect(described_class::FALLBACK_PROMPT).to be_file
    end
  end
end
