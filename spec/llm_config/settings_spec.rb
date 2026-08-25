require_relative "../../lib/mimic"
require_relative "../support/model_keyed_store"
require "tmpdir"
require "fileutils"

RSpec.describe Mimic::LlmConfig::Settings do
  let(:full_cfg) do
    {
      "model" => {
        "path" => "/models/Qwen3-Coder-30B-A3B-UD-Q4_K_M.gguf",
        "search_paths" => [],
        "context_length" => 122_880,
        "mtp" => "on",
      },
      "llama" => {
        "engine" => "ik_llama.cpp",
        "host" => "0.0.0.0",
        "port" => 8080,
        "flash_attn" => "on",
        "cache_type" => "q8_0",
        "n_slots" => 4,
        "binary" => "/usr/bin/llama-server",
      },
    }
  end

  subject(:settings) { described_class.new(full_cfg) }

  describe "#model" do
    it "reads the model section" do
      expect(settings.model.path).to eq("/models/Qwen3-Coder-30B-A3B-UD-Q4_K_M.gguf")
      expect(settings.model.context_length).to eq(122_880)
      expect(settings.model.mtp).to eq("on")
      expect(settings.model.name).to eq("Qwen3-Coder-30B-A3B-UD")
    end

    it "writes back through the wrapped hash" do
      settings.model.path = "/models/other.gguf"
      settings.model.context_length = 4096

      expect(full_cfg["model"]).to include("path" => "/models/other.gguf", "context_length" => 4096)
    end

    it "defaults mtp on an empty section" do
      expect(described_class.new({ "model" => {}, "llama" => {} }).model.mtp).to eq("auto")
    end

    it "resolves the sampling parameters from the chosen model" do
      expect(settings.model.sampling.to_h).to eq(
        "temp" => 0.8, "top-p" => 0.95, "top-k" => 40,
        "min-p" => 0.05, "presence-penalty" => 0.0, "repeat-penalty" => 1.0,
      )
    end

    # 'auto' rather than 'on': it detects from the chat template, so a model
    # with no thinking mode is not forced into one it cannot render.
    it "reads reasoning as auto unless the choices turned it off" do
      expect(settings.model.reasoning).to eq("auto")
      expect(described_class.new({ "model" => { "reasoning" => "off" } }).model.reasoning).to eq("off")
    end

    it "writes the reasoning choice back through the wrapped hash" do
      settings.model.reasoning = "off"

      expect(full_cfg["model"]).to include("reasoning" => "off")
    end

    it "follows path= instead of memoising the name it was read at" do
      expect(settings.model.name).to eq("Qwen3-Coder-30B-A3B-UD")
      settings.model.path = "/models/Gemma-4-31B-Q8_0.gguf"

      expect(settings.model.name).to eq("Gemma-4-31B")
    end

    describe "#file" do
      it "returns a Model for the configured path" do
        expect(settings.model.file).to be_a(Mimic::Model)
        expect(settings.model.file.path.to_s).to eq(settings.model.path)
      end

      it "memoises the same instance across calls" do
        expect(settings.model.file).to equal(settings.model.file)
      end

      it "follows path= instead of memoising the file it was read at" do
        first = settings.model.file
        settings.model.path = "/models/Gemma-4-31B-Q8_0.gguf"

        expect(settings.model.file).not_to equal(first)
        expect(settings.model.file.path.to_s).to eq("/models/Gemma-4-31B-Q8_0.gguf")
      end
    end
  end

  describe "#remember_sampling" do
    include_context "a model-keyed store fixture"

    before { stub_const("Mimic::LlmConfig::MODEL_SAMPLING_PATH", @dir / ".llm/model-sampling.json") }

    def settings_for(reasoning) = described_class.new("model" => { "path" => target_path, "reasoning" => reasoning })

    it "records what the run launched with, under the choice it was taken at" do
      settings_for("auto").remember_sampling

      expect(settings_for("auto").model.file.memory.last_sampling(reasoning: "auto"))
        .to eq(Mimic::LlmConfig::Sampling::DEFAULTS)
      expect(settings_for("off").model.file.memory.last_sampling(reasoning: "off")).to be_nil
    end

    it "is what a later start replays instead of resolving again" do
      settings_for("auto").model.file.memory.remember_sampling("auto", "temperature" => 0.42)

      expect(settings_for("auto").model.sampling.to_h).to include("temp" => 0.42)
    end

    # Re-running setup re-chooses; a value an earlier run settled on must not
    # survive into the preset written for the new choices.
    it "forgets the record so the next start resolves from scratch" do
      settings_for("auto").model.file.memory.remember_sampling("auto", "temperature" => 0.42)
      settings_for("auto").forget_sampling

      expect(settings_for("auto").model.sampling.to_h).to include("temp" => 0.8)
    end
  end

  describe "#llama" do
    it "reads the llama section" do
      expect(settings.llama.engine).to eq("ik_llama.cpp")
      expect(settings.llama.port).to eq(8080)
      expect(settings.llama.host).to eq("0.0.0.0")
      expect(settings.llama.n_slots).to eq(4)
      expect(settings.llama.flash_attn).to eq("on")
      expect(settings.llama.cache_type).to eq("q8_0")
      expect(settings.llama.binary).to eq("/usr/bin/llama-server")
    end

    it "writes back through the wrapped hash" do
      settings.llama.engine = "llama.cpp"
      settings.llama.cache_type = "q4_0"
      settings.llama.n_slots = 8

      expect(full_cfg["llama"]).to include("engine" => "llama.cpp", "cache_type" => "q4_0", "n_slots" => 8)
    end

    it "defaults engine and n_slots on an empty section" do
      llama = described_class.new({ "model" => {}, "llama" => {} }).llama

      expect(llama.engine).to eq("llama.cpp")
      expect(llama.n_slots).to eq(1)
    end

    it "answers ik? and base_url" do
      expect(settings.llama.ik?).to be true
      expect(settings.llama.base_url).to eq("http://127.0.0.1:8080")
    end

    it "keeps llama.cpp and ik_llama.cpp binaries independent" do
      llama = described_class.new({ "model" => {}, "llama" => { "engine" => "llama.cpp" } }).llama
      llama.binary = "/opt/llama.cpp/llama-server"
      llama.engine = "ik_llama.cpp"
      llama.binary = "/opt/ik_llama.cpp/llama-server"

      llama.engine = "llama.cpp"
      expect(llama.binary).to eq("/opt/llama.cpp/llama-server")
      llama.engine = "ik_llama.cpp"
      expect(llama.binary).to eq("/opt/ik_llama.cpp/llama-server")
    end

    it "returns an empty binary when nothing is configured for the current engine" do
      llama = described_class.new({ "model" => {}, "llama" => { "engine" => "llama.cpp", "binary" => {} } }).llama

      expect(llama.binary).to eq("")
    end

    it "survives a config with no llama section at all" do
      expect(described_class.new({ "model" => {} }).llama.engine).to eq("llama.cpp")
    end
  end

  describe "#embed" do
    it "reads the embed section, defaulted, and writes back through the same hash" do
      cfg = { "model" => {}, "llama" => { "host" => "0.0.0.0" }, "embed" => { "path" => "/models/bge-m3-Q8_0.gguf" } }
      embed = described_class.new(cfg).embed

      expect(embed.path).to eq("/models/bge-m3-Q8_0.gguf")
      expect(embed.model_alias).to eq("bge-m3")
      expect(embed.port).to eq(8081)
      expect(embed.mode).to eq("auto")
      expect(embed.batch_size).to eq(8192)
      expect(embed).to be_configured

      embed.port = 8090
      expect(cfg["embed"]["port"]).to eq(8090)

      embed.batch_size = 4096
      expect(cfg["embed"]["batch_size"]).to eq(4096)
    end

    it "is unconfigured when no model was picked" do
      expect(described_class.new({ "model" => {}, "llama" => {} }).embed).not_to be_configured
    end

    # The embed server binds where the chat server does so a container that
    # can reach one can reach the other, but clients always dial loopback.
    it "binds on the llama host and dials loopback" do
      cfg = { "model" => {}, "llama" => { "host" => "0.0.0.0" }, "embed" => { "port" => 8081 } }
      embed = described_class.new(cfg).embed

      expect(embed.host).to eq("0.0.0.0")
      expect(embed.base_url).to eq("http://127.0.0.1:8081")
    end
  end

  describe "#to_h" do
    it "round-trips the plain string-keyed hash" do
      expect(settings.to_h).to eq(full_cfg)
      expect(settings.to_h).to be_a(Hash)
      expect(settings.to_h.keys).to eq(["model", "llama"])
    end
  end

  describe "#mmproj_path / #mmproj_path=" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = Pathname.new(dir)
        %w[vision.gguf mmproj-vision.gguf text-only.gguf].each { |name| FileUtils.touch(@dir / name) }
        example.run
      end
    end

    before do
      stub_const("Mimic::LlmConfig::LLM_CONFIG_DIR", @dir)
      stub_const("Mimic::LlmConfig::LLM_CONFIG_PATH", @dir / "config.yaml")
      stub_const("Mimic::LlmConfig::MODEL_MMPROJ_PATH", @dir / "model-mmproj.json")
    end

    def settings_for(name) = described_class.new({ "model" => { "path" => (@dir / name).to_s }, "llama" => {} })

    def remember(name, projector)
      settings = settings_for(name)
      settings.model.mmproj_path = (@dir / projector).to_s
      settings.save
    end

    # model_path can change without ever running the setup wizard's
    # choose_mmproj step (llm_configure's "model.path" key, parallel_wizard,
    # or a hand-edited config.yaml). Keying the store by model path, like
    # CtxStore, means an unvisited model just has no entry -- there is no
    # stale value left over from whatever model was active before.
    it "does not carry a projector accepted for a different model" do
      remember("vision.gguf", "mmproj-vision.gguf")

      expect(settings_for("text-only.gguf").model.mmproj_path).to be_nil
    end

    it "returns the projector remembered for the current model" do
      remember("vision.gguf", "mmproj-vision.gguf")

      expect(settings_for("vision.gguf").model.mmproj_path).to eq((@dir / "mmproj-vision.gguf").to_s)
    end

    # Every other setter is in-memory until #save; this one wrote straight to
    # disk, so an abandoned wizard run or an unstubbed spec persisted a value
    # nobody committed to.
    it "does not touch the store until save" do
      settings = settings_for("vision.gguf")
      settings.model.mmproj_path = (@dir / "mmproj-vision.gguf").to_s

      expect(Mimic::LlmConfig::MODEL_MMPROJ_PATH).not_to exist
      expect(settings.model.mmproj_path).to eq((@dir / "mmproj-vision.gguf").to_s)
    end

    it "forgets the entry when the projector is set back to nil" do
      remember("vision.gguf", "mmproj-vision.gguf")
      settings = settings_for("vision.gguf")
      settings.model.mmproj_path = nil
      settings.save

      expect(settings_for("vision.gguf").model.mmproj_path).to be_nil
    end

    # A remembered projector can be deleted or moved between runs; handing the
    # missing path to llama-server as --mmproj fails the boot outright.
    it "ignores a remembered projector that is no longer on disk" do
      remember("vision.gguf", "mmproj-vision.gguf")
      (@dir / "mmproj-vision.gguf").unlink

      expect(settings_for("vision.gguf").model.mmproj_path).to be_nil
    end

    it "returns nil when no mmproj_path is stored" do
      cfg = { "model" => { "path" => "/whatever.gguf" } }

      expect(described_class.new(cfg).model.mmproj_path).to be_nil
    end
  end

  describe ".alias_for" do
    it "strips a known quant marker from an arbitrary path" do
      expect(described_class.alias_for("/other/Qwen3-Coder-30B-A3B-UD-Q4_K_M.gguf")).to eq("Qwen3-Coder-30B-A3B-UD")
    end

    it "returns the stem unchanged when no marker matches" do
      expect(described_class.alias_for("/other/plain-model.gguf")).to eq("plain-model")
    end
  end
end

RSpec.describe Mimic::LlmConfig::SearchPaths do
  let(:builtin) { [Pathname.new("/opt/a"), Pathname.new("/opt/b")] }

  before { stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", builtin) }

  def settings_with(paths) = Mimic::LlmConfig::Settings.new({ "model" => { "search_paths" => paths } })

  describe "#all" do
    it "returns the builtin dirs when nothing is configured" do
      expect(settings_with([]).search_paths.to_a).to eq(builtin)
    end

    it "tolerates a config with no model block at all" do
      expect(Mimic::LlmConfig::Settings.new({}).search_paths.to_a).to eq(builtin)
    end

    it "appends configured dirs after the builtins" do
      expect(settings_with(["/mnt/models"]).search_paths.to_a)
        .to eq(builtin + [Pathname.new("/mnt/models")])
    end

    it "expands ~ in a configured dir" do
      expect(settings_with(["~/extra"]).search_paths.to_a.last)
        .to eq(Pathname.new(Dir.home) / "extra")
    end

    it "drops a configured dir that duplicates a builtin" do
      expect(settings_with(["/opt/a"]).search_paths.to_a).to eq(builtin)
    end
  end

  describe "#add" do
    it "adds an unknown dir and reports it" do
      settings = settings_with([])
      expect(settings.search_paths.add("/mnt/models")).to eq(:added)
      expect(settings.to_h["model"]["search_paths"]).to eq(["/mnt/models"])
    end

    it "stores the expanded path, not the literal ~" do
      settings = settings_with([])
      settings.search_paths.add("~/extra")
      expect(settings.to_h["model"]["search_paths"]).to eq([(Pathname.new(Dir.home) / "extra").to_s])
    end

    it "reports a builtin dir as already searched and does not store it" do
      settings = settings_with([])
      expect(settings.search_paths.add("/opt/a")).to eq(:builtin)
      expect(settings.to_h["model"]["search_paths"]).to eq([])
    end

    it "reports a duplicate without adding it twice" do
      settings = settings_with(["/mnt/models"])
      expect(settings.search_paths.add("/mnt/models")).to eq(:duplicate)
      expect(settings.to_h["model"]["search_paths"]).to eq(["/mnt/models"])
    end

    it "adds a model block to a config that has none" do
      settings = Mimic::LlmConfig::Settings.new({})
      expect(settings.search_paths.add("/mnt/models")).to eq(:added)
      expect(settings.to_h["model"]["search_paths"]).to eq(["/mnt/models"])
    end
  end

  describe "#remove" do
    it "removes a configured dir" do
      settings = settings_with(["/mnt/models"])
      expect(settings.search_paths.remove("/mnt/models")).to eq(:removed)
      expect(settings.to_h["model"]["search_paths"]).to eq([])
    end

    it "matches an unexpanded ~ against the stored absolute path" do
      settings = settings_with([(Pathname.new(Dir.home) / "extra").to_s])
      expect(settings.search_paths.remove("~/extra")).to eq(:removed)
      expect(settings.to_h["model"]["search_paths"]).to eq([])
    end

    it "reports a builtin dir as not removable" do
      expect(settings_with([]).search_paths.remove("/opt/a")).to eq(:builtin)
    end

    it "reports an unknown dir" do
      expect(settings_with([]).search_paths.remove("/nope")).to eq(:missing)
    end

    it "leaves the stored list untouched when nothing matched" do
      settings = settings_with(["/mnt/models"])
      settings.search_paths.remove("/nope")
      expect(settings.to_h["model"]["search_paths"]).to eq(["/mnt/models"])
    end
  end
end
