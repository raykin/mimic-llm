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
    allow(Open3).to receive(:capture2).and_return(["0.134.0\n", instance_double(Process::Status, success?: true)])
    allow(Mimic::Agent).to receive(:spawn_and_wait).and_return(0)
  end

  def codex_reports(version_output, success: true)
    allow(Open3).to receive(:capture2).and_return([version_output, instance_double(Process::Status, success?: success)])
  end

  describe "#launch" do
    it "aborts when codex isn't installed and install isn't allowed" do
      allow(Mimic::Util::Probes).to receive(:which).with("codex").and_return(nil)
      expect do
        expect { agent.launch([]) }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end.to output(/codex binary not found/).to_stderr
    end

    it "aborts on a codex too old to read the unsloth_api profile file" do
      codex_reports("codex-cli 0.133.0\n")
      expect do
        expect { agent.launch([]) }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end.to output(%r{Codex 0\.134\.0 or newer is needed, but /usr/bin/codex is 0\.133\.0}).to_stderr
      expect(Mimic::Agent).not_to have_received(:spawn_and_wait)
    end

    it "still launches when the codex version cannot be read" do
      codex_reports("", success: false)
      agent.launch([])
      expect(Mimic::Agent).to have_received(:spawn_and_wait)
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

    def user_codex = @user_home / ".codex"

    it "links the user's AGENTS.md and skills into a home that lacks them" do
      (user_codex / "skills/demo").mkpath
      (user_codex / "AGENTS.md").write("be brief\n")

      agent.launch([])

      expect((home / "AGENTS.md").read).to eq("be brief\n")
      expect((home / "skills").realpath).to eq((user_codex / "skills").realpath)
      expect(home / "prompts").not_to exist
    end

    # Codex appends approvals to rules/default.rules, so a linked rules
    # folder would write the home's approvals into the user's own file.
    it "gives a fresh home its own rules folder holding the user's rules" do
      (user_codex / "rules").mkpath
      (user_codex / "rules/default.rules").write("user_rule()\n")
      (user_codex / "rules/open.rules").write("open_rule()\n")

      agent.launch([])

      expect(home / "rules").not_to be_symlink
      expect((home / "rules/user-default.rules").read).to eq("user_rule()\n")
      expect((home / "rules/open.rules").read).to eq("open_rule()\n")
      expect(home / "rules/default.rules").not_to exist
    end

    it "adds the user's skills and rules into the folders a used home already has" do
      (user_codex / "skills/demo").mkpath
      (user_codex / "rules").mkpath
      (user_codex / "rules/default.rules").write("user_rule()\n")
      (home / "skills/.system").mkpath
      (home / "rules").mkpath
      (home / "rules/default.rules").write("home_rule()\n")

      agent.launch([])

      expect(home / "skills").not_to be_symlink
      expect(home / "skills/.system").to be_directory
      expect((home / "skills/demo").realpath).to eq((user_codex / "skills/demo").realpath)
      expect((home / "rules/default.rules").read).to eq("home_rule()\n")
      expect((home / "rules/user-default.rules").read).to eq("user_rule()\n")
    end

    # Codex skips a *.rules file that is a symlink.
    it "puts a symlinked user rule into the home as a real file" do
      (@user_home / "dotfile").mkpath
      (@user_home / "dotfile/open.rules").write("open_rule()\n")
      (user_codex / "rules").mkpath
      (user_codex / "rules/open.rules").make_symlink(@user_home / "dotfile/open.rules")

      agent.launch([])

      expect(home / "rules/open.rules").not_to be_symlink
      expect((home / "rules/open.rules").read).to eq("open_rule()\n")
    end

    it "links an entry the user adds later and drops a link whose source is gone" do
      (user_codex / "skills/demo").mkpath
      agent.launch([])
      (user_codex / "AGENTS.md").write("be brief\n")
      (user_codex / "skills/demo").rmdir
      (user_codex / "skills").rmdir

      agent.launch([])

      expect((home / "AGENTS.md").read).to eq("be brief\n")
      expect(home / "skills").not_to be_symlink
      expect(home / "skills").not_to exist
    end

    it "writes model catalog fields only when the context length is known" do
      agent.launch([])

      catalog = JSON.parse((home / "model-catalog.json").read)
      entry = catalog["models"].first
      expect(entry["context_window"]).to eq(4096)
      expect(entry["max_context_window"]).to eq(4096)
    end

    it "offers the freeform apply_patch tool in the model catalog" do
      agent.launch([])

      entry = JSON.parse((home / "model-catalog.json").read)["models"].first
      expect(entry["apply_patch_tool_type"]).to eq("freeform")
    end

    it "keeps patch line endings only on a codex new enough to know the feature" do
      agent.launch([])
      expect((home / "unsloth_api.config.toml").read).not_to include("apply_patch_preserve_line_endings")

      allow(Open3).to receive(:capture2).and_return(["codex-cli 0.148.0\n", instance_double(Process::Status, success?: true)])
      agent.launch([])
      profile = (home / "unsloth_api.config.toml").read
      expect(profile).to include("features.apply_patch_preserve_line_endings = true")
      expect(profile).to include("suppress_unstable_features_warning = true")
    end

    it "unsets inherited OpenAI and Codex credentials" do
      agent.launch([])

      expect(Mimic::Agent).to have_received(:spawn_and_wait)
        .with(anything, hash_including("OPENAI_API_KEY" => nil, "CODEX_API_KEY" => nil, "CODEX_ACCESS_TOKEN" => nil))
    end

    it "omits model catalog context window fields when context_length is nil" do
      nil_settings = settings_double(nil)

      described_class.new(nil_settings).launch([])

      catalog = JSON.parse((home / "model-catalog.json").read)
      entry = catalog["models"].first
      expect(entry).not_to have_key("context_window")
    end

    it "writes no context window for a context length of 0" do
      described_class.new(settings_double(0)).launch([])

      entry = JSON.parse((home / "model-catalog.json").read)["models"].first
      expect(entry).not_to have_key("context_window")
      expect((home / "unsloth_api.config.toml").read).not_to include("model_context_window")
    end
  end

  describe "FALLBACK_PROMPT" do
    it "resolves beside this module, not the old lib/mimic root" do
      expect(described_class::FALLBACK_PROMPT).to be_file
    end
  end
end
