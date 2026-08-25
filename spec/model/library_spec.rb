require_relative "../../lib/mimic"
require_relative "../../lib/mimic/model/library"
require_relative "../support/gguf_writer"
require "tmpdir"
require "fileutils"

RSpec.describe Mimic::Model::Library do
  around do |example|
    Dir.mktmpdir do |dir|
      @packing_store = Pathname.new(dir) / "model-packing.json"
      example.run
    end
  end

  before { stub_const("Mimic::Model::Memory::TERNARY_PACKING_PATH", @packing_store) }

  def library(cfg = { "model" => {}, "llama" => {} })
    described_class.new(Mimic::LlmConfig::Settings.new(cfg))
  end

  describe "#all" do
    # The picker must not offer a model whose symlink target is gone --
    # choosing it dies with "Model file not found" and exits the wizard.
    it "skips a dangling symlink" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        FileUtils.touch(root / "real.gguf")
        (root / "gone.gguf").make_symlink(root / "deleted.gguf")
        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [])

        found = library({ "model" => { "search_paths" => [root.to_s] } }).all

        expect(found.map { |m| m.path.to_s }).to eq([(root / "real.gguf").to_s])
      end
    end

    it "collects .gguf files from every scan dir that exists" do
      Dir.mktmpdir do |tmp|
        root = Pathname.new(tmp)
        FileUtils.touch(root / "b.gguf")
        FileUtils.touch(root / "a.gguf")
        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])

        expect(library.all.map { |m| m.path.to_s })
          .to eq([(root / "a.gguf").to_s, (root / "b.gguf").to_s])
      end
    end

    it "skips scan dirs that don't exist" do
      dir = instance_double(Pathname, directory?: false)
      stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [dir])
      expect(library.all).to eq([])
    end

    it "scans the dirs LlmConfig resolves, recursively" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        (root / "nested").mkpath
        FileUtils.touch(root / "nested/model.gguf")
        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [])

        found = library({ "model" => { "search_paths" => [root.to_s] } }).all

        expect(found.map { |m| m.path.to_s }).to eq([(root / "nested/model.gguf").to_s])
      end
    end

    it "attaches an mmproj file to its model instead of listing it as one" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        FileUtils.touch(root / "model.gguf")
        GgufWriter.write(root / "mmproj-model.gguf", { "general.type" => "mmproj" })
        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])

        found = library.all

        expect(found.map { |m| m.path.basename.to_s }).to contain_exactly("model.gguf")
        expect(found.first.projector).to eq(root / "mmproj-model.gguf")
      end
    end

    it "scans once per library, however many lists are asked for" do
      Dir.mktmpdir do |tmp|
        root = Pathname.new(tmp)
        FileUtils.touch(root / "a.gguf")
        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])
        instance = library
        allow(Dir).to receive(:glob).and_call_original

        instance.chat
        instance.embedding

        expect(Dir).to have_received(:glob).once
      end
    end
  end

  describe "#chat" do
    def models_dir
      root = Pathname.new(Dir.mktmpdir)
      GgufWriter.write(root / "plain.gguf", { "general.architecture" => "llama" },
                       tensors: [["blk.0.attn_q.weight", 4096, 12, 4096]])
      GgufWriter.write(root / "bonsai-g128.gguf", { "general.architecture" => "qwen35" },
                       tensors: [["blk.0.attn_q.weight", 34_000, 42, 128_000]])
      GgufWriter.write(root / "bonsai-g64.gguf", { "general.architecture" => "qwen35" },
                       tensors: [["blk.0.attn_q.weight", 18_000, 42, 64_000]])
      root
    end

    def offered(engine, root)
      stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])
      cfg = { "model" => { "search_paths" => [] }, "llama" => { "engine" => engine } }
      library(cfg).chat.map { |m| m.path.basename.to_s }
    end

    it "hides the fork's ternary packing from upstream llama.cpp" do
      root = models_dir

      expect(offered("llama.cpp", root)).to contain_exactly("plain.gguf", "bonsai-g64.gguf")
    end

    it "offers the prism fork only its own G128 ternary models, not plain GGUFs too" do
      root = models_dir

      expect(offered("prism-llama.cpp", root)).to contain_exactly("bonsai-g128.gguf")
    end

    it "hides every ternary packing from ik_llama.cpp, which has no Q2_0 at all" do
      root = models_dir

      expect(offered("ik_llama.cpp", root)).to contain_exactly("plain.gguf")
    end

    # Sorting the picker's list means reading every model's tensor block,
    # ~0.12s a file. A second wizard run must answer from the sidecar.
    it "reads each model's packing through its memory, not straight off the header" do
      root = models_dir
      offered("llama.cpp", root)

      expect_any_instance_of(Mimic::Model::Gguf).not_to receive(:tensors)
      expect(offered("llama.cpp", root)).to contain_exactly("plain.gguf", "bonsai-g64.gguf")
    end

    it "leaves embedding models out" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        GgufWriter.write(root / "chat-Q4_K_M.gguf", { "general.architecture" => "qwen3", "qwen3.block_count" => 48 })
        GgufWriter.write(root / "bge-m3-Q8_0.gguf", { "general.architecture" => "bert", "bert.attention.causal" => 0 })
        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])

        expect(library.chat.map { |m| m.path.basename.to_s }).to eq(["chat-Q4_K_M.gguf"])
      end
    end
  end

  describe "#hidden" do
    it "names the chat models the engine's packing rules excluded" do
      root = Pathname.new(Dir.mktmpdir)
      GgufWriter.write(root / "plain.gguf", { "general.architecture" => "llama" },
                       tensors: [["blk.0.attn_q.weight", 4096, 12, 4096]])
      GgufWriter.write(root / "bonsai-g128.gguf", { "general.architecture" => "qwen35" },
                       tensors: [["blk.0.attn_q.weight", 34_000, 42, 128_000]])
      stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])
      cfg = { "model" => { "search_paths" => [] }, "llama" => { "engine" => "llama.cpp" } }

      expect(library(cfg).hidden.map { |m| m.path.basename.to_s }).to eq(["bonsai-g128.gguf"])
    end

    # An embedding model is not offered by the chat picker either, but it is
    # not hidden -- `llm embed` owns it, and reporting it as unreadable would
    # be a lie.
    it "does not count an embedding model as hidden" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        GgufWriter.write(root / "bge-m3-Q8_0.gguf", { "general.architecture" => "bert", "bert.attention.causal" => 0 })
        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])

        expect(library.hidden).to eq([])
      end
    end
  end

  describe "#embedding" do
    it "keeps only the embedding models the scan found" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        GgufWriter.write(root / "chat-Q4_K_M.gguf", { "general.architecture" => "qwen3", "qwen3.block_count" => 48 })
        GgufWriter.write(root / "bge-m3-Q8_0.gguf", { "general.architecture" => "bert", "bert.attention.causal" => 0 })
        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])

        expect(library.embedding.map { |m| m.path.basename.to_s }).to eq(["bge-m3-Q8_0.gguf"])
      end
    end
  end
end
