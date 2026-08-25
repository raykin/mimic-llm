require_relative "../../lib/mimic"
require_relative "../../lib/mimic/model/upstream"
require_relative "../support/gguf_writer"
require "tmpdir"
require "fileutils"

RSpec.describe Mimic::Model::Upstream do
  FakeHf = Struct.new(:trees) do
    def tree(repo_id) = trees[repo_id]
  end

  def entry(path, size, date: "2026-08-14T16:04:14.000Z")
    { "type" => "file", "path" => path, "size" => size, "lastCommit" => { "date" => date } }
  end

  def upstream(path, trees)
    described_class.new(Mimic::Model.new(path), client: FakeHf.new(trees))
  end

  describe "#repo_id" do
    it "reads owner and repo off an LM Studio path" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        model = root / ".lmstudio" / "models" / "unsloth" / "gemma-4-31B-it-GGUF" / "gemma-4-31B-it-Q4_K_S.gguf"
        model.dirname.mkpath
        FileUtils.touch(model)
        stub_const("Mimic::Model::Upstream::LMSTUDIO_ROOT", root / ".lmstudio" / "models")

        expect(upstream(model, {}).repo_id).to eq("unsloth/gemma-4-31B-it-GGUF")
      end
    end

    # general.repo_url carries the quantizer's org and nothing else -- the
    # repo half of the id has to come from the directory the file sits in.
    it "combines the header's owner with the containing directory" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir) / "Qwen3.8-27B-GGUF"
        root.mkpath
        model = root / "Qwen3.8-27B-UD-Q4_K_XL.gguf"
        GgufWriter.write(model, { "general.repo_url" => "https://huggingface.co/unsloth" })

        expect(upstream(model, {}).repo_id).to eq("unsloth/Qwen3.8-27B-GGUF")
      end
    end

    it "is nil when the header names no repo and the path is not LM Studio's" do
      Dir.mktmpdir do |dir|
        model = Pathname.new(dir) / "Ternary-Bonsai-27B-Q2_0.gguf"
        GgufWriter.write(model, { "general.name" => "Bonsai-27B" })

        expect(upstream(model, {}).repo_id).to be_nil
      end
    end
  end

  describe "#verdict" do
    def qwen(trees)
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir) / "Qwen3.8-27B-GGUF"
        root.mkpath
        model = root / "Qwen3.8-27B-UD-Q4_K_XL.gguf"
        GgufWriter.write(model, { "general.repo_url" => "https://huggingface.co/unsloth" })
        yield upstream(model, trees.call(model.size))
      end
    end

    it "is :current when the upstream file is the same size" do
      qwen(->(size) { { "unsloth/Qwen3.8-27B-GGUF" => [entry("Qwen3.8-27B-UD-Q4_K_XL.gguf", size)] } }) do |subject|
        expect(subject.verdict).to eq(:current)
      end
    end

    it "is :stale when the upstream file has been re-quantized to a different size" do
      qwen(->(size) { { "unsloth/Qwen3.8-27B-GGUF" => [entry("Qwen3.8-27B-UD-Q4_K_XL.gguf", size + 4096)] } }) do |subject|
        expect(subject.verdict).to eq(:stale)
      end
    end

    it "matches on basename so a file published under a subdirectory still resolves" do
      qwen(->(size) { { "unsloth/Qwen3.8-27B-GGUF" => [entry("UD/Qwen3.8-27B-UD-Q4_K_XL.gguf", size)] } }) do |subject|
        expect(subject.verdict).to eq(:current)
      end
    end

    it "is :gone when the repo no longer publishes that filename" do
      qwen(->(_size) { { "unsloth/Qwen3.8-27B-GGUF" => [entry("Qwen3.8-27B-Q4_K_M.gguf", 10)] } }) do |subject|
        expect(subject.verdict).to eq(:gone)
      end
    end

    it "is :unknown when the repo id cannot be resolved" do
      Dir.mktmpdir do |dir|
        model = Pathname.new(dir) / "Ternary-Bonsai-27B-Q2_0.gguf"
        GgufWriter.write(model, {})

        expect(upstream(model, {}).verdict).to eq(:unknown)
      end
    end

    it "is :unknown when the client could not fetch the tree" do
      qwen(->(_size) { { "unsloth/Qwen3.8-27B-GGUF" => nil } }) do |subject|
        expect(subject.verdict).to eq(:unknown)
      end
    end
  end

  describe "#updated_at" do
    it "returns the matched file's last commit date" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir) / "Qwen3.8-27B-GGUF"
        root.mkpath
        model = root / "Qwen3.8-27B-UD-Q4_K_XL.gguf"
        GgufWriter.write(model, { "general.repo_url" => "https://huggingface.co/unsloth" })
        trees = { "unsloth/Qwen3.8-27B-GGUF" => [entry("Qwen3.8-27B-UD-Q4_K_XL.gguf", model.size)] }

        expect(upstream(model, trees).updated_at).to eq("2026-08-14")
      end
    end

    it "is nil when nothing matched" do
      Dir.mktmpdir do |dir|
        model = Pathname.new(dir) / "loose.gguf"
        GgufWriter.write(model, {})

        expect(upstream(model, {}).updated_at).to be_nil
      end
    end
  end
end
