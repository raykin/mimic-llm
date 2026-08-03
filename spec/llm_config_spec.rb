require_relative "../lib/mimic"
require "tmpdir"
require "fileutils"

RSpec.describe Mimic::LlmConfig do
  describe "the model-ctx store" do
    # Finding A, decided 2026-07-28 in Python's favour: the store is keyed by
    # the resolved model path, so a model reached through ~/hf-models and the
    # same model reached at its .lmstudio target share one entry.
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = Pathname.new(dir)
        (@dir / "store").mkpath
        FileUtils.touch(@dir / "store/model.gguf")
        (@dir / "alias.gguf").make_symlink(@dir / "store/model.gguf")
        example.run
      end
    end

    before do
      stub_const("Mimic::LlmConfig::LLM_CONFIG_DIR", @dir / ".llm")
      stub_const("Mimic::LlmConfig::MODEL_CTX_PATH", @dir / ".llm/model-ctx.json")
    end

    def cfg_for(path)
      {
        "model" => { "path" => path.to_s, "context_length" => 4096 },
        "llama" => { "cache_type" => "q8_0" },
      }
    end

    it "keys by the symlink target, so either path recalls the same entry" do
      described_class::Settings.new(cfg_for(@dir / "alias.gguf")).remember_ctx

      written = JSON.parse(Mimic::LlmConfig::MODEL_CTX_PATH.read)
      expect(written.keys).to eq([(@dir / "store/model.gguf").realpath.to_s])
      expect(described_class.recall_ctx((@dir / "alias.gguf").to_s)).to eq([4096, "q8_0"])
      expect(described_class.recall_ctx((@dir / "store/model.gguf").to_s)).to eq([4096, "q8_0"])
    end

    # Reading and relocating the store are internal steps of remember_ctx /
    # recall_ctx; nothing outside this module may reach for them.
    it "keeps the store reader and the legacy relocation off the public surface" do
      expect { described_class.load_ctx_store }.to raise_error(NoMethodError)
      expect { described_class.migrate_legacy }.to raise_error(NoMethodError)
    end

    it "recalls nothing for a path that does not exist" do
      expect(described_class.recall_ctx((@dir / "gone.gguf").to_s)).to be_nil
    end

    it "recalls nothing instead of raising when the store is unreadable" do
      described_class::Settings.new(cfg_for(@dir / "alias.gguf")).remember_ctx
      Mimic::LlmConfig::MODEL_CTX_PATH.chmod(0o000)

      expect(described_class.recall_ctx((@dir / "alias.gguf").to_s)).to be_nil
    end
  end

  describe ".load" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = Pathname.new(dir)
        example.run
      end
    end

    before do
      stub_const("Mimic::LlmConfig::LLM_CONFIG_PATH", @dir / "config.yaml")
      stub_const("Mimic::LlmConfig::LEGACY_CONFIG", @dir / "absent.yaml")
    end

    it "loads a config that carries a date scalar" do
      Mimic::LlmConfig::LLM_CONFIG_PATH.write("last_used: 2026-07-28\nllama:\n  port: 9090\n")

      cfg = described_class.load
      expect(cfg).to be_a(Mimic::LlmConfig::Settings)
      expect(cfg.port).to eq(9090)
      expect(cfg.host).to eq("127.0.0.1")
    end
  end

  describe "Settings#save" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = Pathname.new(dir)
        example.run
      end
    end

    before { stub_const("Mimic::LlmConfig::LLM_CONFIG_PATH", @dir / "config.yaml") }

    it "writes the wrapped config" do
      described_class::Settings.new({ "llama" => { "port" => 9090 } }).save
      expect(Psych.safe_load(Mimic::LlmConfig::LLM_CONFIG_PATH.read)).to eq("llama" => { "port" => 9090 })
    end

    # config.yaml is the model + llama profile and nothing else; the mimic
    # wizard already sliced on the way out, and both wizards now agree.
    it "writes only the model and llama sections" do
      described_class::Settings.new({ "llama" => { "port" => 9090 }, "stray" => 1 }).save
      expect(Psych.safe_load(Mimic::LlmConfig::LLM_CONFIG_PATH.read).keys).to eq(["llama"])
    end
  end

  describe ".merge" do
    it "deep merges nested hashes without mutating base" do
      base = { "a" => { "x" => 1, "y" => 2 } }
      override = { "a" => { "y" => 99 } }
      merged = described_class.merge(base, override)
      expect(merged).to eq({ "a" => { "x" => 1, "y" => 99 } })
      expect(base).to eq({ "a" => { "x" => 1, "y" => 2 } })
    end
  end
end

RSpec.describe Mimic::LlmConfig::Settings, "model search paths" do
  let(:builtin) { [Pathname.new("/opt/a"), Pathname.new("/opt/b")] }

  before { stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", builtin) }

  def settings_with(paths) = described_class.new({ "model" => { "search_paths" => paths } })

  describe "#search_paths" do
    it "returns the builtin dirs when nothing is configured" do
      expect(settings_with([]).search_paths).to eq(builtin)
    end

    it "tolerates a config with no model block at all" do
      expect(described_class.new({}).search_paths).to eq(builtin)
    end

    it "appends configured dirs after the builtins" do
      expect(settings_with(["/mnt/models"]).search_paths)
        .to eq(builtin + [Pathname.new("/mnt/models")])
    end

    it "expands ~ in a configured dir" do
      expect(settings_with(["~/extra"]).search_paths.last)
        .to eq(Pathname.new(Dir.home) / "extra")
    end

    it "drops a configured dir that duplicates a builtin" do
      expect(settings_with(["/opt/a"]).search_paths).to eq(builtin)
    end
  end

  describe "#add_search_path" do
    it "adds an unknown dir and reports it" do
      settings = settings_with([])
      expect(settings.add_search_path("/mnt/models")).to eq(:added)
      expect(settings.to_h["model"]["search_paths"]).to eq(["/mnt/models"])
    end

    it "stores the expanded path, not the literal ~" do
      settings = settings_with([])
      settings.add_search_path("~/extra")
      expect(settings.to_h["model"]["search_paths"]).to eq([(Pathname.new(Dir.home) / "extra").to_s])
    end

    it "reports a builtin dir as already searched and does not store it" do
      settings = settings_with([])
      expect(settings.add_search_path("/opt/a")).to eq(:builtin)
      expect(settings.to_h["model"]["search_paths"]).to eq([])
    end

    it "reports a duplicate without adding it twice" do
      settings = settings_with(["/mnt/models"])
      expect(settings.add_search_path("/mnt/models")).to eq(:duplicate)
      expect(settings.to_h["model"]["search_paths"]).to eq(["/mnt/models"])
    end

    it "adds a model block to a config that has none" do
      settings = described_class.new({})
      expect(settings.add_search_path("/mnt/models")).to eq(:added)
      expect(settings.to_h["model"]["search_paths"]).to eq(["/mnt/models"])
    end
  end

  describe "#remove_search_path" do
    it "removes a configured dir" do
      settings = settings_with(["/mnt/models"])
      expect(settings.remove_search_path("/mnt/models")).to eq(:removed)
      expect(settings.to_h["model"]["search_paths"]).to eq([])
    end

    it "matches an unexpanded ~ against the stored absolute path" do
      settings = settings_with([(Pathname.new(Dir.home) / "extra").to_s])
      expect(settings.remove_search_path("~/extra")).to eq(:removed)
      expect(settings.to_h["model"]["search_paths"]).to eq([])
    end

    it "reports a builtin dir as not removable" do
      expect(settings_with([]).remove_search_path("/opt/a")).to eq(:builtin)
    end

    it "reports an unknown dir" do
      expect(settings_with([]).remove_search_path("/nope")).to eq(:missing)
    end

    it "leaves the stored list untouched when nothing matched" do
      settings = settings_with(["/mnt/models"])
      settings.remove_search_path("/nope")
      expect(settings.to_h["model"]["search_paths"]).to eq(["/mnt/models"])
    end
  end
end
