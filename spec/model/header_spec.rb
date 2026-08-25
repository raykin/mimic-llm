require_relative "../../lib/mimic"
require_relative "../support/gguf_writer"
require "tmpdir"

RSpec.describe Mimic::Model::Header do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  subject(:header) { described_class.new(path) }

  describe "#moe?" do
    let(:path) { @dir / "moe.gguf" }

    it "is true when expert_count is non-zero" do
      GgufWriter.write(path, { "general.architecture" => "qwen3", "qwen3.expert_count" => 128 })
      expect(header.moe?).to be true
    end
  end

  describe "#embedding?" do
    let(:path) { @dir / "bge.gguf" }

    it "is true for an encoder with causal attention off" do
      GgufWriter.write(path, { "general.architecture" => "bert", "bert.attention.causal" => 0 })
      expect(header.embedding?).to be true
    end
  end

  describe "#pooling_type" do
    let(:path) { @dir / "bge.gguf" }

    it "reads the pooling type for the model's architecture" do
      GgufWriter.write(path, { "general.architecture" => "bert", "bert.pooling_type" => 2 })
      expect(header.pooling_type).to eq(2)
    end
  end

  describe "#block_count" do
    let(:path) { @dir / "moe.gguf" }

    it "reads block_count for the model's architecture" do
      GgufWriter.write(path, { "general.architecture" => "qwen3moe", "qwen3moe.block_count" => 48 })
      expect(header.block_count).to eq(48)
    end
  end

  describe "#ternary_packing" do
    let(:path) { @dir / "g128.gguf" }

    it "reports the fork's 128-weight packing" do
      tensors = [
        ["token_embd.weight", 4096, 8, 4096],
        ["blk.0.attn_q.weight", 1000 * 34, 42, 1000 * 128],
      ]
      GgufWriter.write(path, { "general.architecture" => "qwen35" }, tensors: tensors)

      expect(header.ternary_packing).to eq(:g128)
    end
  end

  describe "#expert_bytes_per_layer" do
    let(:path) { @dir / "moe-tensors.gguf" }

    it "averages the expert tensor bytes over the layers that carry them" do
      tensors = [
        ["blk.0.ffn_up_exps.weight", 4 * 1024 * 1024],
        ["blk.0.ffn_down_exps.weight", 2 * 1024 * 1024],
      ]
      GgufWriter.write(path, { "general.architecture" => "llama", "llama.block_count" => 1 }, tensors: tensors)

      expect(header.expert_bytes_per_layer).to eq(6 * 1024 * 1024)
    end
  end

  describe "#metadata" do
    it "stops before a vocab-sized string array by default" do
      path = @dir / "vocab.gguf"
      GgufWriter.write(path, {
                         "general.architecture" => "llama",
                         "llama.block_count" => 32,
                         "tokenizer.ggml.tokens" => GgufWriter::StringArray.new(Array.new(5000) { |i| "tok#{i}" }),
                         "general.file_type" => 15,
                       })

      expect(described_class.new(path).metadata).not_to have_key("general.file_type")
    end

    it "reads past it when full: true is asked for" do
      path = @dir / "vocab-full.gguf"
      GgufWriter.write(path, {
                         "general.architecture" => "llama",
                         "llama.block_count" => 32,
                         "tokenizer.ggml.tokens" => GgufWriter::StringArray.new(Array.new(5000) { |i| "tok#{i}" }),
                         "general.file_type" => 15,
                       })

      expect(described_class.new(path).metadata(full: true)["general.file_type"]).to eq(15)
    end
  end

  it "is nil rather than raising for a missing or unreadable file" do
    header = described_class.new(@dir / "missing.gguf")

    expect(header.moe?).to be_nil
    expect(header.embedding?).to be_nil
    expect(header.pooling_type).to be_nil
    expect(header.block_count).to be_nil
  end

  it "reads the header only once across several calls" do
    path = @dir / "chat.gguf"
    GgufWriter.write(path, { "general.architecture" => "qwen3", "qwen3.expert_count" => 0 })
    header = described_class.new(path)
    expect(Mimic::Model::Schema).to receive(:read_metadata).once.and_call_original

    header.moe?
    header.embedding?
    header.block_count
  end
end
