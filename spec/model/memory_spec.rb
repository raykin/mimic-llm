require_relative "../../lib/mimic"
require_relative "../support/model_keyed_store"
require_relative "../support/gguf_writer"
require "tmpdir"
require "fileutils"

RSpec.describe Mimic::Model::Memory do
  def memory_for(path) = Mimic::Model.new(path).memory

  describe "#last_ctx / #remember_ctx" do
    include_context "a model-keyed store fixture"

    before { stub_const("Mimic::LlmConfig::MODEL_CTX_PATH", store_path) }

    def store_path = @dir / ".llm/model-ctx.json"
    def stored_value = [4096, "q8_0"]
    def remember_entry(path) = memory_for(path).remember_ctx(4096, "q8_0")
    def recall_entry(path) = memory_for(path).last_ctx

    it_behaves_like "a store keyed by the resolved model path"

    it "recalls nothing for a model it has never seen" do
      expect(memory_for(@dir / "gone.gguf").last_ctx).to be_nil
    end
  end

  describe "#compute_mib / #remember_compute" do
    include_context "a model-keyed store fixture"

    before { stub_const("Mimic::LlmConfig::MODEL_COMPUTE_PATH", store_path) }

    def store_path = @dir / ".llm/model-compute.json"
    def stored_value = 900
    def remember_entry(path) = memory_for(path).remember_compute(4096, "q8_0", stored_value)
    def recall_entry(path) = memory_for(path).compute_mib(4096, "q8_0")

    it_behaves_like "a store keyed by the resolved model path"

    it "recalls nothing for a different ctx or cache type" do
      model = memory_for(target_path)
      model.remember_compute(131_072, "q8_0", 2431)

      expect(model.compute_mib(65_536, "q8_0")).to be_nil
      expect(model.compute_mib(131_072, "f16")).to be_nil
    end

    it "keeps entries for other contexts of the same model" do
      model = memory_for(target_path)
      model.remember_compute(65_536, "q8_0", 1800)
      model.remember_compute(131_072, "q8_0", 2431)

      expect(model.compute_mib(65_536, "q8_0")).to eq(1800)
      expect(model.compute_mib(131_072, "q8_0")).to eq(2431)
    end
  end

  describe "#sampling_for / #remember_sampling" do
    include_context "a model-keyed store fixture"

    before { stub_const("Mimic::LlmConfig::MODEL_SAMPLING_PATH", store_path) }

    def store_path = @dir / ".llm/model-sampling.json"
    def stored_value = { "temperature" => 0.7 }
    def remember_entry(path) = memory_for(path).remember_sampling("auto", stored_value)
    def recall_entry(path) = memory_for(path).last_sampling(reasoning: "auto")

    it_behaves_like "a store keyed by the resolved model path"

    it "replays the values a successful run recorded" do
      model = memory_for(target_path)
      model.remember_sampling("auto", "temperature" => 0.7, "top_k" => 64)

      expect(model.sampling_for(reasoning: "auto")).to eq("temperature" => 0.7, "top_k" => 64)
    end

    # The record is what the wizard's choices resolved to, so a choice the
    # record was not taken under has to be resolved again rather than replayed.
    it "ignores a record taken under the other reasoning choice" do
      model = memory_for(target_path)
      model.remember_sampling("auto", "temperature" => 0.7)

      expect(model.sampling_for(reasoning: "off")).to eq(Mimic::LlmConfig::Sampling::DEFAULTS)
    end

    # A record written before the choice was spelled the engines' way carries
    # no reasoning value, so it cannot claim to have been taken under one.
    it "ignores a record left by the pre-rename thinking key" do
      Mimic::Model::Store.new(store_path)
                         .write(target_path.to_s, "thinking" => true, "values" => { "temperature" => 0.7 })

      expect(memory_for(target_path).sampling_for(reasoning: "auto"))
        .to eq(Mimic::LlmConfig::Sampling::DEFAULTS)
    end

    it "resolves from the header when no run has succeeded yet" do
      path = @dir / "fresh.gguf"
      GgufWriter.write(path, { "general.sampling.temp" => 1.0, "general.sampling.top_k" => 64 })

      expect(memory_for(path).sampling_for(reasoning: "auto"))
        .to include("temperature" => 1.0, "top_k" => 64, "min_p" => 0.05)
    end

    it "falls back to the defaults when the header cannot be read" do
      expect(memory_for(@dir / "gone.gguf").sampling_for(reasoning: "auto"))
        .to eq(Mimic::LlmConfig::Sampling::DEFAULTS)
    end
  end

  describe "#n_cpu_moe / #remember_n_cpu_moe / #forget_n_cpu_moe" do
    include_context "a model-keyed store fixture"

    before { stub_const("Mimic::Model::Memory::N_CPU_MOE_PATH", store_path) }

    def store_path = @dir / ".llm/ik-n-cpu-moe.json"
    def stored_value = 12
    def remember_entry(path) = memory_for(path).remember_n_cpu_moe(stored_value)
    def recall_entry(path) = memory_for(path).n_cpu_moe

    it_behaves_like "a store keyed by the resolved model path"

    it "recalls nothing for a model it has never seen" do
      expect(memory_for(@dir / "gone.gguf").n_cpu_moe).to be_nil
    end

    it "forgets a remembered value" do
      model = memory_for(target_path)
      model.remember_n_cpu_moe(8)

      model.forget_n_cpu_moe

      expect(model.n_cpu_moe).to be_nil
    end
  end

  describe "#mmproj / #mmproj=" do
    include_context "a model-keyed store fixture"

    before { stub_const("Mimic::LlmConfig::MODEL_MMPROJ_PATH", store_path) }

    def store_path = @dir / ".llm/model-mmproj.json"
    def stored_value = "/models/mmproj-F32.gguf"
    def remember_entry(path) = memory_for(path).mmproj = stored_value
    def recall_entry(path) = memory_for(path).mmproj

    it_behaves_like "a store keyed by the resolved model path"

    it "drops the entry rather than storing a nil projector" do
      memory = memory_for(target_path)
      memory.mmproj = stored_value

      memory.mmproj = nil

      expect(JSON.parse(store_path.read)).to eq({})
    end
  end

  describe "#effort / #effort=" do
    include_context "a model-keyed store fixture"

    before { stub_const("Mimic::LlmConfig::MODEL_EFFORT_PATH", store_path) }

    def store_path = @dir / ".llm/model-effort.json"
    def stored_value = "low"
    def remember_entry(path) = memory_for(path).effort = stored_value
    def recall_entry(path) = memory_for(path).effort

    it_behaves_like "a store keyed by the resolved model path"

    it "drops the entry when the level is cleared" do
      memory = memory_for(target_path)
      memory.effort = stored_value

      memory.effort = nil

      expect(JSON.parse(store_path.read)).to eq({})
    end
  end

  describe "#ternary_packing" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = Pathname.new(dir)
        example.run
      end
    end

    before { stub_const("Mimic::Model::Memory::TERNARY_PACKING_PATH", @dir / ".llm/model-packing.json") }

    # Reading the packing means reading the tensor block, which sits behind
    # the vocab array -- ~0.12s of exhaustive KV walk per model, paid for
    # every model the setup picker lists.
    def g128_model
      path = @dir / "bonsai.gguf"
      GgufWriter.write(path, { "general.architecture" => "qwen35" },
                       tensors: [["blk.0.attn_q.weight", 34_000, 42, 128_000]])
      path
    end

    def plain_model
      path = @dir / "plain.gguf"
      GgufWriter.write(path, { "general.architecture" => "llama" },
                       tensors: [["blk.0.attn_q.weight", 4096, 12, 4096]])
      path
    end

    it "parses the header once and answers later asks from the sidecar" do
      path = g128_model
      expect(memory_for(path).ternary_packing).to eq(:g128)

      expect_any_instance_of(Mimic::Model::Gguf).not_to receive(:tensors)
      expect(memory_for(path).ternary_packing).to eq(:g128)
    end

    # Most models are not ternary at all, so a nil that is not cached leaves
    # the whole picker paying the walk on every run.
    it "caches a plain model's nil" do
      path = plain_model
      expect(memory_for(path).ternary_packing).to be_nil

      expect_any_instance_of(Mimic::Model::Gguf).not_to receive(:tensors)
      expect(memory_for(path).ternary_packing).to be_nil
    end

    it "re-parses when the file changed since it was cached" do
      path = g128_model
      memory_for(path).ternary_packing
      plain = plain_model
      FileUtils.cp(plain, path)

      expect(memory_for(path).ternary_packing).to be_nil
    end

    it "answers without caching when the file cannot be stat'd" do
      expect(memory_for(@dir / "gone.gguf").ternary_packing).to be_nil
      expect(@dir / ".llm/model-packing.json").not_to exist
    end
  end
end
