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

  describe "#supports_mtp?" do
    it "is true when the header carries nextn_predict_layers" do
      path = @dir / "mtp.gguf"
      path.write("GGUF\x00nextn_predict_layers\x00", mode: "wb")

      expect(described_class.new(path).supports_mtp?).to be true
    end

    it "is false when it does not" do
      path = @dir / "plain.gguf"
      path.write("GGUF\x00llama.block_count\x00", mode: "wb")

      expect(described_class.new(path).supports_mtp?).to be false
    end

    # A directory, an unreadable file and a missing path all answer false
    # rather than raising out of render_preset.
    it "is false for a directory, an unreadable file and a missing path" do
      unreadable = @dir / "locked.gguf"
      unreadable.write("nextn_predict_layers")
      unreadable.chmod(0o000)

      expect(described_class.new(@dir).supports_mtp?).to be false
      expect(described_class.new(unreadable).supports_mtp?).to be false
      expect(described_class.new(@dir / "missing.gguf").supports_mtp?).to be false
    end
  end

  describe "unreadable input" do
    %i[moe? embedding? pooling_type block_count ternary_packing expert_bytes_per_layer].each do |reader|
      it "#{reader} is nil for a missing file and for a file that is not a GGUF" do
        not_gguf = @dir / "nope.bin"
        not_gguf.write("nope")

        expect(described_class.new(@dir / "missing.gguf").public_send(reader)).to be_nil
        expect(described_class.new(not_gguf).public_send(reader)).to be_nil
      end
    end

    it "is nil for a header cut mid-value" do
      path = @dir / "stub.gguf"
      GgufWriter.write(path, { "general.architecture" => "llama", "llama.block_count" => 32 })
      path.write(path.read(6)[0, 6], mode: "wb")

      expect(described_class.new(path).block_count).to be_nil
    end
  end

  describe "#moe?" do
    it "is true when expert_count is non-zero" do
      path = @dir / "moe.gguf"
      GgufWriter.write(path, { "general.architecture" => "qwen3", "qwen3.expert_count" => 128 })
      expect(described_class.new(path).moe?).to be true
    end

    it "is false when expert_count is zero or absent" do
      path = @dir / "dense.gguf"
      GgufWriter.write(path, { "general.architecture" => "qwen3", "qwen3.expert_count" => 0 })
      expect(described_class.new(path).moe?).to be false
    end

    it "is nil when the header carries no architecture key" do
      path = @dir / "no-arch.gguf"
      GgufWriter.write(path, { "general.name" => "mystery" })
      expect(described_class.new(path).moe?).to be_nil
    end
  end

  describe "#embedding?" do
    it "is true for an encoder with causal attention off" do
      path = @dir / "bge.gguf"
      GgufWriter.write(path, { "general.architecture" => "bert", "bert.attention.causal" => 0 })
      expect(described_class.new(path).embedding?).to be true
    end

    it "is true when the header carries a pooling type" do
      path = @dir / "pooled.gguf"
      GgufWriter.write(path, { "general.architecture" => "qwen3", "qwen3.pooling_type" => 1 })
      expect(described_class.new(path).embedding?).to be true
    end

    it "is true for a known encoder architecture with neither key" do
      path = @dir / "jina.gguf"
      GgufWriter.write(path, { "general.architecture" => "jina-bert-v2", "jina-bert-v2.block_count" => 12 })
      expect(described_class.new(path).embedding?).to be true
    end

    it "is false for a causal chat model" do
      path = @dir / "chat.gguf"
      GgufWriter.write(path, { "general.architecture" => "qwen3", "qwen3.block_count" => 48 })
      expect(described_class.new(path).embedding?).to be false
    end
  end

  describe "#pooling_type" do
    it "reads the pooling type for the model's architecture" do
      path = @dir / "bge.gguf"
      GgufWriter.write(path, { "general.architecture" => "bert", "bert.pooling_type" => 2 })
      expect(described_class.new(path).pooling_type).to eq(2)
    end

    it "is nil when the header carries no pooling type" do
      path = @dir / "rerank.gguf"
      GgufWriter.write(path, { "general.architecture" => "bert", "bert.block_count" => 24 })
      expect(described_class.new(path).pooling_type).to be_nil
    end
  end

  describe "#block_count" do
    it "reads block_count for the model's architecture" do
      path = @dir / "moe.gguf"
      GgufWriter.write(path, { "general.architecture" => "qwen3moe", "qwen3moe.block_count" => 48 })
      expect(described_class.new(path).block_count).to eq(48)
    end

    it "is nil when the header carries no architecture key" do
      path = @dir / "no-arch.gguf"
      GgufWriter.write(path, { "general.name" => "mystery" })
      expect(described_class.new(path).block_count).to be_nil
    end
  end

  describe "#ternary_packing" do
    def ternary_model(name, type:, block_weights:, block_bytes:)
      path = @dir / name
      blocks = 1000
      tensors = [
        ["token_embd.weight", 4096, 8, 4096],
        ["blk.0.attn_q.weight", blocks * block_bytes, type, blocks * block_weights],
      ]
      GgufWriter.write(path, { "general.architecture" => "qwen35" }, tensors: tensors)
      path
    end

    it "reports the fork's 128-weight packing" do
      path = ternary_model("g128.gguf", type: 42, block_weights: 128, block_bytes: 34)

      expect(described_class.new(path).ternary_packing).to eq(:g128)
    end

    it "reports mainline's 64-weight packing under the same type id" do
      path = ternary_model("g64.gguf", type: 42, block_weights: 64, block_bytes: 18)

      expect(described_class.new(path).ternary_packing).to eq(:g64)
    end

    it "reports a type no engine here defines as unsupported" do
      path = ternary_model("legacy.gguf", type: 142, block_weights: 128, block_bytes: 34)

      expect(described_class.new(path).ternary_packing).to eq(:unsupported)
    end

    it "returns nil for a model with no ternary tensors" do
      path = @dir / "q4.gguf"
      GgufWriter.write(path, { "general.architecture" => "llama" },
                       tensors: [["blk.0.attn_q.weight", 4096, 12, 4096]])

      expect(described_class.new(path).ternary_packing).to be_nil
    end
  end

  describe "#expert_bytes_per_layer" do
    it "averages the expert tensor bytes over the layers that carry them" do
      path = @dir / "moe.gguf"
      tensors = [
        ["blk.0.ffn_up_exps.weight", 4 * 1024 * 1024],
        ["blk.0.ffn_down_exps.weight", 2 * 1024 * 1024],
        ["blk.1.ffn_up_exps.weight", 4 * 1024 * 1024],
        ["blk.1.ffn_down_exps.weight", 2 * 1024 * 1024],
        ["blk.0.attn_q.weight", 1024],
      ]
      GgufWriter.write(path, { "general.architecture" => "llama", "llama.block_count" => 2 }, tensors: tensors)

      expect(described_class.new(path).expert_bytes_per_layer).to eq(6 * 1024 * 1024)
    end

    it "returns nil when no tensor is an expert tensor" do
      path = @dir / "dense.gguf"
      GgufWriter.write(path, { "general.architecture" => "llama" }, tensors: [["blk.0.ffn_up.weight", 4096]])

      expect(described_class.new(path).expert_bytes_per_layer).to be_nil
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

    it "is an empty hash rather than a raise for an unreadable file" do
      expect(described_class.new(@dir / "missing.gguf").metadata).to eq({})
    end
  end

  it "reads the header only once across several calls" do
    path = @dir / "chat.gguf"
    GgufWriter.write(path, { "general.architecture" => "qwen3", "qwen3.expert_count" => 0 })
    header = described_class.new(path)
    header.moe?

    expect(File).not_to receive(:open)

    header.embedding?
    header.block_count
  end
end
