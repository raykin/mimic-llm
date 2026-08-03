require_relative "../lib/mimic"

RSpec.describe Mimic::LlmConfig::Settings do
  let(:full_cfg) do
    {
      "model" => {
        "path" => "/models/Qwen3-Coder-30B-A3B-UD-Q4_K_M.gguf",
        "search_paths" => [],
        "context_length" => 122_880,
        "mtp" => "on",
        "temperature" => 0.6,
        "top_p" => 0.95,
        "top_k" => 20,
        "min_p" => 0.0,
        "presence_penalty" => 1.5,
        "repeat_penalty" => 1.0,
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

  it "reads model_path, context_length, cache_type" do
    expect(settings.model_path).to eq("/models/Qwen3-Coder-30B-A3B-UD-Q4_K_M.gguf")
    expect(settings.context_length).to eq(122_880)
    expect(settings.cache_type).to eq("q8_0")
  end

  it "reads engine, port, host, n_slots, flash_attn, binary" do
    expect(settings.engine).to eq("ik_llama.cpp")
    expect(settings.port).to eq(8080)
    expect(settings.host).to eq("0.0.0.0")
    expect(settings.n_slots).to eq(4)
    expect(settings.flash_attn).to eq("on")
    expect(settings.binary).to eq("/usr/bin/llama-server")
  end

  it "reads the sampling parameters" do
    expect(settings.temperature).to eq(0.6)
    expect(settings.top_p).to eq(0.95)
    expect(settings.top_k).to eq(20)
    expect(settings.min_p).to eq(0.0)
    expect(settings.presence_penalty).to eq(1.5)
    expect(settings.repeat_penalty).to eq(1.0)
  end

  it "reads mtp" do
    expect(settings.mtp).to eq("on")
  end

  describe "defaults" do
    subject(:settings) { described_class.new({ "model" => {}, "llama" => {} }) }

    it "defaults engine to llama.cpp" do
      expect(settings.engine).to eq("llama.cpp")
    end

    it "defaults n_slots to 1" do
      expect(settings.n_slots).to eq(1)
    end

    it "defaults mtp to auto" do
      expect(settings.mtp).to eq("auto")
    end
  end

  describe "#ik?" do
    it "is true for the ik_llama.cpp engine" do
      expect(settings.ik?).to be true
    end

    it "is false for llama.cpp" do
      cfg = { "model" => {}, "llama" => { "engine" => "llama.cpp" } }
      expect(described_class.new(cfg).ik?).to be false
    end
  end

  describe "#model_alias" do
    it "strips a known quant marker" do
      expect(settings.model_alias).to eq("Qwen3-Coder-30B-A3B-UD")
    end

    it "returns the stem unchanged when no marker matches" do
      cfg = { "model" => { "path" => "/models/plain-model.gguf" } }
      expect(described_class.new(cfg).model_alias).to eq("plain-model")
    end

    it "follows model_path= instead of memoising the alias it was read at" do
      expect(settings.model_alias).to eq("Qwen3-Coder-30B-A3B-UD")
      settings.model_path = "/models/Gemma-4-31B-Q8_0.gguf"
      expect(settings.model_alias).to eq("Gemma-4-31B")
    end
  end

  describe "#base_url" do
    it "always targets loopback, never the server's bind address" do
      expect(settings.base_url).to eq("http://127.0.0.1:8080")
    end
  end

  describe "#to_h" do
    it "round-trips the plain string-keyed hash" do
      expect(settings.to_h).to eq(full_cfg)
      expect(settings.to_h).to be_a(Hash)
      expect(settings.to_h.keys).to eq(["model", "llama"])
    end
  end

  describe "write accessors" do
    it "write through to the wrapped hash" do
      settings.model_path = "/models/other.gguf"
      settings.context_length = 4096
      settings.cache_type = "q4_0"
      settings.engine = "llama.cpp"
      settings.binary = "/usr/local/bin/llama-server"
      settings.n_slots = 8

      expect(settings.model_path).to eq("/models/other.gguf")
      expect(settings.context_length).to eq(4096)
      expect(settings.cache_type).to eq("q4_0")
      expect(settings.engine).to eq("llama.cpp")
      expect(settings.binary).to eq("/usr/local/bin/llama-server")
      expect(settings.n_slots).to eq(8)
      expect(full_cfg["model"]["path"]).to eq("/models/other.gguf")
      expect(full_cfg["llama"]["n_slots"]).to eq(8)
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
