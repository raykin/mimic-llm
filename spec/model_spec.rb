require_relative "../lib/mimic"
require_relative "support/model_keyed_store"
require_relative "support/gguf_writer"
require "tmpdir"
require "fileutils"

RSpec.describe Mimic::Model do
  def in_tmp
    Dir.mktmpdir { |dir| yield Pathname.new(dir) }
  end

  # A real header, not a filename, is what marks a projector -- llama.cpp's
  # own convert scripts write general.type == "mmproj" regardless of what
  # the file is named.
  def write_projector(path)
    GgufWriter.write(path, { "general.type" => "mmproj", "clip.has_vision_encoder" => 1 })
  end

  describe ".projector?" do
    it "recognises a projector by its header, whatever it's named" do
      in_tmp do |root|
        write_projector(root / "vision-part2.gguf")

        expect(described_class.projector?(root / "vision-part2.gguf")).to be true
      end
    end

    it "does not mistake a plain model, even one named mmproj-something, for a projector" do
      in_tmp do |root|
        FileUtils.touch(root / "mmproj-shaped-name.gguf")

        expect(described_class.projector?(root / "mmproj-shaped-name.gguf")).to be false
      end
    end
  end

  describe ".projector_for" do
    it "pairs a projector that carries no model stem at all" do
      in_tmp do |root|
        model = root / "gemma-4-31B-it-Q4_K_S.gguf"
        projector = root / "mmproj-F32.gguf"
        FileUtils.touch(model)
        write_projector(projector)

        expect(described_class.projector_for(model)).to eq(projector)
      end
    end

    it "prefers the stem-matching projector when a directory holds several" do
      in_tmp do |root|
        model = root / "Bonsai-27B-Q4_K_M.gguf"
        FileUtils.touch(model)
        [root / "mmproj-F32.gguf", root / "mmproj-Bonsai-27B-BF16.gguf"].each { |p| write_projector(p) }

        expect(described_class.projector_for(model)).to eq(root / "mmproj-Bonsai-27B-BF16.gguf")
      end
    end

    it "pairs a projector whose mmproj marker is suffixed onto the model's own name" do
      in_tmp do |root|
        model = root / "Ternary-Bonsai-27B-Q2_0.gguf"
        projector = root / "Ternary-Bonsai-27B-mmproj-Q8_0.gguf"
        FileUtils.touch(model)
        write_projector(projector)

        expect(described_class.projector_for(model)).to eq(projector)
      end
    end

    it "declines to guess between unrelated projectors" do
      in_tmp do |root|
        model = root / "model-Q4_K_M.gguf"
        FileUtils.touch(model)
        [root / "mmproj-alpha-f16.gguf", root / "mmproj-beta-f16.gguf"].each { |p| write_projector(p) }

        expect(described_class.projector_for(model)).to be_nil
      end
    end

    it "looks beside the symlink target, not beside the symlink" do
      in_tmp do |root|
        store = root / "store"
        links = root / "links"
        [store, links].each(&:mkpath)
        target = store / "model-Q4_K_M.gguf"
        projector = store / "mmproj-F32.gguf"
        FileUtils.touch(target)
        write_projector(projector)
        link = links / "model-Q4_K_M.gguf"
        FileUtils.ln_s(target, link)

        expect(described_class.projector_for(link)).to eq(projector)
      end
    end

    it "returns nil when the model file is gone" do
      expect(described_class.projector_for(Pathname.new("/nowhere/model.gguf"))).to be_nil
    end
  end

  describe ".pair" do
    it "drops projectors from the list and attaches them to their model" do
      in_tmp do |root|
        model = root / "model-Q4_K_M.gguf"
        projector = root / "mmproj-F32.gguf"
        FileUtils.touch(model)
        write_projector(projector)

        paired = described_class.pair([[model, root], [projector, root]])

        expect(paired.map(&:path)).to eq([model])
        expect(paired.first.projector).to eq(projector)
        expect(paired.first).to be_vision
      end
    end

    it "leaves a text-only model without a projector" do
      in_tmp do |root|
        model = root / "model-Q4_K_M.gguf"
        FileUtils.touch(model)

        paired = described_class.pair([[model, root]])

        expect(paired.first.projector).to be_nil
        expect(paired.first).not_to be_vision
      end
    end
  end

  describe "#embedding?" do
    it "asks the GGUF header, resolved through the symlink" do
      in_tmp do |root|
        store = root / "store"
        links = root / "links"
        [store, links].each(&:mkpath)
        target = store / "bge-m3-Q8_0.gguf"
        GgufWriter.write(target, { "general.architecture" => "bert", "bert.attention.causal" => 0 })
        link = links / "bge-m3-Q8_0.gguf"
        FileUtils.ln_s(target, link)

        expect(described_class.new(link, links)).to be_embedding
      end
    end

    it "is false for a generative model" do
      in_tmp do |root|
        model = root / "chat-Q4_K_M.gguf"
        GgufWriter.write(model, { "general.architecture" => "qwen3", "qwen3.block_count" => 48 })

        expect(described_class.new(model, root)).not_to be_embedding
      end
    end

    it "is false for a file with no readable header" do
      in_tmp do |root|
        model = root / "empty.gguf"
        FileUtils.touch(model)

        expect(described_class.new(model, root)).not_to be_embedding
      end
    end
  end

  describe "#model_alias" do
    it "strips the quant marker the same way the config does" do
      model = described_class.new(Pathname.new("/m/Bonsai-27B-Q4_K_M.gguf"), Pathname.new("/m"))

      expect(model.model_alias).to eq("Bonsai-27B")
    end
  end

  describe "#path" do
    it "returns the path it was built with" do
      expect(described_class.new("/models/model-Q4_K_M.gguf").path.to_s).to eq("/models/model-Q4_K_M.gguf")
    end
  end

  describe "#last_ctx / #remember_ctx" do
    include_context "a model-keyed store fixture"

    before { stub_const("Mimic::LlmConfig::MODEL_CTX_PATH", store_path) }

    def store_path = @dir / ".llm/model-ctx.json"
    def stored_value = [4096, "q8_0"]
    def remember_entry(path) = described_class.new(path).remember_ctx(4096, "q8_0")
    def recall_entry(path) = described_class.new(path).last_ctx

    it_behaves_like "a store keyed by the resolved model path"

    it "recalls nothing for a model it has never seen" do
      expect(described_class.new(@dir / "gone.gguf").last_ctx).to be_nil
    end
  end

  describe "#compute_mib / #remember_compute" do
    include_context "a model-keyed store fixture"

    before { stub_const("Mimic::LlmConfig::MODEL_COMPUTE_PATH", store_path) }

    def store_path = @dir / ".llm/model-compute.json"
    def stored_value = 900
    def remember_entry(path) = described_class.new(path).remember_compute(4096, "q8_0", stored_value)
    def recall_entry(path) = described_class.new(path).compute_mib(4096, "q8_0")

    it_behaves_like "a store keyed by the resolved model path"

    it "recalls nothing for a different ctx or cache type" do
      model = described_class.new(target_path)
      model.remember_compute(131_072, "q8_0", 2431)

      expect(model.compute_mib(65_536, "q8_0")).to be_nil
      expect(model.compute_mib(131_072, "f16")).to be_nil
    end

    it "keeps entries for other contexts of the same model" do
      model = described_class.new(target_path)
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
    def remember_entry(path) = described_class.new(path).remember_sampling("auto", stored_value)
    def recall_entry(path) = described_class.new(path).last_sampling(reasoning: "auto")

    it_behaves_like "a store keyed by the resolved model path"

    it "replays the values a successful run recorded" do
      model = described_class.new(target_path)
      model.remember_sampling("auto", "temperature" => 0.7, "top_k" => 64)

      expect(model.sampling_for(reasoning: "auto")).to eq("temperature" => 0.7, "top_k" => 64)
    end

    # The record is what the wizard's choices resolved to, so a choice the
    # record was not taken under has to be resolved again rather than replayed.
    it "ignores a record taken under the other reasoning choice" do
      model = described_class.new(target_path)
      model.remember_sampling("auto", "temperature" => 0.7)

      expect(model.sampling_for(reasoning: "off")).to eq(Mimic::LlmConfig::Sampling::DEFAULTS)
    end

    # A record written before the choice was spelled the engines' way carries
    # no reasoning value, so it cannot claim to have been taken under one.
    it "ignores a record left by the pre-rename thinking key" do
      Mimic::Model::Store.new(store_path)
                         .write(target_path.to_s, "thinking" => true, "values" => { "temperature" => 0.7 })

      expect(described_class.new(target_path).sampling_for(reasoning: "auto"))
        .to eq(Mimic::LlmConfig::Sampling::DEFAULTS)
    end

    it "resolves from the header when no run has succeeded yet" do
      path = @dir / "fresh.gguf"
      GgufWriter.write(path, { "general.sampling.temp" => 1.0, "general.sampling.top_k" => 64 })

      expect(described_class.new(path).sampling_for(reasoning: "auto"))
        .to include("temperature" => 1.0, "top_k" => 64, "min_p" => 0.05)
    end

    it "falls back to the defaults when the header cannot be read" do
      expect(described_class.new(@dir / "gone.gguf").sampling_for(reasoning: "auto"))
        .to eq(Mimic::LlmConfig::Sampling::DEFAULTS)
    end
  end

  describe "#n_cpu_moe / #remember_n_cpu_moe / #forget_n_cpu_moe" do
    include_context "a model-keyed store fixture"

    before { stub_const("Mimic::Model::N_CPU_MOE_PATH", store_path) }

    def store_path = @dir / ".llm/ik-n-cpu-moe.json"
    def stored_value = 12
    def remember_entry(path) = described_class.new(path).remember_n_cpu_moe(stored_value)
    def recall_entry(path) = described_class.new(path).n_cpu_moe

    it_behaves_like "a store keyed by the resolved model path"

    it "recalls nothing for a model it has never seen" do
      expect(described_class.new(@dir / "gone.gguf").n_cpu_moe).to be_nil
    end

    it "forgets a remembered value" do
      model = described_class.new(target_path)
      model.remember_n_cpu_moe(8)

      model.forget_n_cpu_moe

      expect(model.n_cpu_moe).to be_nil
    end
  end

  describe "#preflight" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = Pathname.new(dir)
        example.run
      end
    end

    def model_path(**extra)
      path = @dir / "model.gguf"
      GgufWriter.write(path, {
                          "general.architecture" => "llama",
                          "llama.block_count" => 1,
                          "llama.attention.head_count_kv" => 1,
                          "llama.attention.key_length" => 1,
                        }.merge(extra))
      path
    end

    it "flags a context that fits within budget" do
      allow(Mimic::Model::Vram).to receive(:gpu_total_mib).and_return(24_000)

      est = described_class.new(model_path).preflight(100, "q8_0")
      expect(est[:fits]).to be true
      expect(est[:total_mib]).to eq(24_000)
    end

    it "returns nil when the GPU can't be queried" do
      allow(Mimic::Model::Vram).to receive(:gpu_total_mib).and_return(nil)
      expect(described_class.new(model_path).preflight(100, "q8_0")).to be_nil
    end

    it "returns nil when the model file is not a GGUF" do
      path = @dir / "not-gguf.bin"
      path.write("nope")
      allow(Mimic::Model::Vram).to receive(:gpu_total_mib).and_return(24_000)

      expect(described_class.new(path).preflight(100, "q8_0")).to be_nil
    end

    # A vision model's projector is loaded onto the GPU with --mmproj, so a
    # budget that only counts the decoder is short by its whole size -- 1.7 GB
    # for Ornith's mmproj-F32.gguf.
    it "counts the projector that loads beside the model" do
      allow(Mimic::Model::Vram).to receive(:gpu_total_mib).and_return(24_000)
      path = model_path
      alone = described_class.new(path).preflight(100, "q8_0")

      GgufWriter.write(@dir / "mmproj-F32.gguf", { "general.type" => "mmproj" },
                       tensors: [["data", 3 * 1024 * 1024]])
      paired = described_class.new(path).preflight(100, "q8_0")

      expect(paired[:weights_mib]).to be_within(0.01).of(alone[:weights_mib] + 3)
      expect(paired[:max_ctx]).to be < alone[:max_ctx]
    end

    # The budget is what's left after the desktop reserve, and the estimate has
    # to carry the compute-buffer headroom -- a ctx that only fits by ignoring
    # either one loads and then dies once the KV cache fills.
    it "subtracts the desktop reserve and the compute headroom from the budget" do
      allow(Mimic::Model::Vram).to receive(:gpu_total_mib).and_return(24_000)

      est = described_class.new(model_path).preflight(100, "q8_0")
      expect(est[:budget_mib]).to eq(24_000 - Mimic::Model::Vram::DESKTOP_RESERVE_MIB)
      expect(est[:need_mib]).to be > Mimic::Model::Vram.compute_default(24_000)
    end

    # The default is a flat guess tuned to one model at one context. A launch
    # that measured the real cost passes it in, and the guess steps aside.
    it "prefers a measured compute cost over the default" do
      allow(Mimic::Model::Vram).to receive(:gpu_total_mib).and_return(24_000)
      path = model_path

      guessed = described_class.new(path).preflight(100, "q8_0")
      measured = described_class.new(path).preflight(100, "q8_0", compute_mib: 512)

      expect(guessed[:need_mib] - measured[:need_mib])
        .to be_within(0.01).of(Mimic::Model::Vram.compute_default(24_000) - 512)
      expect(measured[:max_ctx]).to be > guessed[:max_ctx]
    end

    it "budgets a 12 GiB card with the smaller guard, not the 3090's" do
      allow(Mimic::Model::Vram).to receive(:gpu_total_mib).and_return(12_288)

      est = described_class.new(model_path).preflight(100, "q8_0")
      expect(est[:need_mib] - est[:weights_mib] - est[:kv_mib]).to be_within(0.01).of(1024)
    end
  end
end
