require_relative "../lib/mimic"
require "tmpdir"
require "fileutils"

RSpec.describe Mimic::LlmConfig do
  it "keeps the legacy relocation off the public surface" do
    expect { described_class.migrate_legacy }.to raise_error(NoMethodError)
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
      expect(cfg.llama.port).to eq(9090)
      expect(cfg.llama.host).to eq("0.0.0.0")
    end
  end

  # model.mmproj_path and a flat llama.binary both predate the per-model /
  # per-engine stores that replaced them. Neither is read any more, so a
  # config written before the split silently loses its projector and hands
  # whichever engine is configured the other one's binary unless load
  # relocates both.
  describe ".load migrating a pre-store config" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = Pathname.new(dir)
        %w[vision.gguf mmproj-vision.gguf].each { |name| FileUtils.touch(@dir / name) }
        example.run
      end
    end

    before do
      stub_const("Mimic::LlmConfig::LLM_CONFIG_DIR", @dir)
      stub_const("Mimic::LlmConfig::LLM_CONFIG_PATH", @dir / "config.yaml")
      stub_const("Mimic::LlmConfig::MODEL_MMPROJ_PATH", @dir / "model-mmproj.json")
      stub_const("Mimic::LlmConfig::LEGACY_CONFIG", @dir / "absent.yaml")
    end

    def write_config(model:, llama: {})
      Mimic::LlmConfig::LLM_CONFIG_PATH.write(Psych.dump("model" => model, "llama" => llama))
    end

    it "moves a flat mmproj_path into the per-model store and drops the key" do
      write_config(model: { "path" => (@dir / "vision.gguf").to_s,
                            "mmproj_path" => (@dir / "mmproj-vision.gguf").to_s })

      expect(described_class.load.model.mmproj_path).to eq((@dir / "mmproj-vision.gguf").to_s)
      expect(Psych.safe_load(Mimic::LlmConfig::LLM_CONFIG_PATH.read)["model"]).not_to have_key("mmproj_path")
    end

    it "drops an empty mmproj_path key without storing an entry" do
      write_config(model: { "path" => (@dir / "vision.gguf").to_s, "mmproj_path" => nil })

      expect(described_class.load.model.mmproj_path).to be_nil
      expect(Psych.safe_load(Mimic::LlmConfig::LLM_CONFIG_PATH.read)["model"]).not_to have_key("mmproj_path")
      expect(Mimic::LlmConfig::MODEL_MMPROJ_PATH).not_to exist
    end

    it "attributes a flat binary string to the engine that was configured with it" do
      write_config(model: {}, llama: { "engine" => "ik_llama.cpp", "binary" => "/opt/ik/llama-server" })

      expect(described_class.load.llama.binary).to eq("/opt/ik/llama-server")
      expect(Psych.safe_load(Mimic::LlmConfig::LLM_CONFIG_PATH.read)["llama"]["binary"])
        .to eq("ik_llama.cpp" => "/opt/ik/llama-server")
    end

    it "leaves the other engine's binary unset rather than sharing the migrated one" do
      write_config(model: {}, llama: { "engine" => "ik_llama.cpp", "binary" => "/opt/ik/llama-server" })

      cfg = described_class.load
      cfg.llama.engine = "llama.cpp"
      expect(cfg.llama.binary).to eq("")
    end

    it "drops the sampler keys, which the model's own header now answers for" do
      write_config(model: { "path" => (@dir / "vision.gguf").to_s, "temperature" => 0.6,
                            "top_p" => 0.95, "top_k" => 20, "min_p" => 0.0,
                            "presence_penalty" => 1.5, "repeat_penalty" => 1.0 })

      described_class.load
      stored = Psych.safe_load(Mimic::LlmConfig::LLM_CONFIG_PATH.read)["model"]
      expect(stored.keys).not_to include(*Mimic::LlmConfig::Sampling::KEYS)
    end

    # The choice used to be a boolean spelled `thinking`, translated to the
    # engines' value at read time. It is stored as that value now, so a
    # config written before the rename has to be translated once, on disk.
    it "translates a legacy thinking flag into the reasoning value" do
      write_config(model: { "path" => (@dir / "vision.gguf").to_s, "thinking" => false })

      expect(described_class.load.model.reasoning).to eq("off")
      stored = Psych.safe_load(Mimic::LlmConfig::LLM_CONFIG_PATH.read)["model"]
      expect(stored).to include("reasoning" => "off")
      expect(stored).not_to have_key("thinking")
    end

    it "translates a thinking flag that was left on" do
      write_config(model: { "path" => (@dir / "vision.gguf").to_s, "thinking" => true })

      expect(described_class.load.model.reasoning).to eq("auto")
      expect(Psych.safe_load(Mimic::LlmConfig::LLM_CONFIG_PATH.read)["model"]).not_to have_key("thinking")
    end

    it "rewrites nothing when there is nothing to migrate" do
      write_config(model: { "path" => (@dir / "vision.gguf").to_s }, llama: { "binary" => {} })
      before_mtime = Mimic::LlmConfig::LLM_CONFIG_PATH.mtime

      described_class.load
      expect(Mimic::LlmConfig::LLM_CONFIG_PATH.mtime).to eq(before_mtime)
    end
  end

  describe "Settings#save" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = Pathname.new(dir)
        example.run
      end
    end

    # save mkpaths the directory as well as writing the file, so stubbing the
    # path alone leaves the real ~/.llm being created by the suite.
    before do
      stub_const("Mimic::LlmConfig::LLM_CONFIG_DIR", @dir)
      stub_const("Mimic::LlmConfig::LLM_CONFIG_PATH", @dir / "config.yaml")
    end

    it "writes the wrapped config" do
      described_class::Settings.new({ "llama" => { "port" => 9090 } }).save
      expect(Psych.safe_load(Mimic::LlmConfig::LLM_CONFIG_PATH.read)).to eq("llama" => { "port" => 9090 })
    end

    # config.yaml is the model + llama + embed profile and nothing else; the
    # mimic wizard already sliced on the way out, and both wizards now agree.
    it "writes only the model, llama and embed sections" do
      described_class::Settings.new({ "llama" => { "port" => 9090 }, "stray" => 1 }).save
      expect(Psych.safe_load(Mimic::LlmConfig::LLM_CONFIG_PATH.read).keys).to eq(["llama"])
    end

    it "keeps the embed section" do
      described_class::Settings.new({ "embed" => { "port" => 8081 }, "stray" => 1 }).save
      expect(Psych.safe_load(Mimic::LlmConfig::LLM_CONFIG_PATH.read).keys).to eq(["embed"])
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
