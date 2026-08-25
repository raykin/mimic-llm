require_relative "../../lib/mimic"
require_relative "../support/gguf_writer"
require "tmpdir"

RSpec.describe Mimic::Model::Schema do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  describe "unparseable input" do
    %i[moe? embedding? pooling_type block_count ternary_packing expert_bytes_per_layer].each do |reader|
      it "#{reader} is nil for a missing file and for a file that is not a GGUF" do
        not_gguf = @dir / "nope.bin"
        not_gguf.write("nope")

        expect(described_class.public_send(reader, @dir / "missing.gguf")).to be_nil
        expect(described_class.public_send(reader, not_gguf)).to be_nil
      end
    end
  end

  describe ".read_metadata" do
    it "reads scalar and string kv pairs from a GGUF header" do
      path = @dir / "model.gguf"
      GgufWriter.write(path, { "general.architecture" => "llama", "llama.block_count" => 32 })

      meta = described_class.read_metadata(path)
      expect(meta["general.architecture"]).to eq("llama")
      expect(meta["llama.block_count"]).to eq(32)
    end

    it "skips over a small string array and keeps reading later keys" do
      path = @dir / "tags.gguf"
      GgufWriter.write(path, {
                         "general.architecture" => "llama",
                         "general.tags" => GgufWriter::StringArray.new(%w[text-generation gguf]),
                         "llama.block_count" => 32,
                       })

      meta = described_class.read_metadata(path)
      expect(meta["llama.block_count"]).to eq(32)
      expect(meta).not_to have_key("general.tags")
    end

    it "stops at a vocab-sized string array once the architecture block is read" do
      path = @dir / "vocab.gguf"
      GgufWriter.write(path, {
                         "general.architecture" => "llama",
                         "llama.block_count" => 32,
                         "tokenizer.ggml.tokens" => GgufWriter::StringArray.new(Array.new(5000) { |i| "tok#{i}" }),
                         "general.file_type" => 15,
                       })

      meta = described_class.read_metadata(path)
      expect(meta["llama.block_count"]).to eq(32)
      expect(meta).not_to have_key("general.file_type")
      expect(described_class.read_metadata(path, full: true)["general.file_type"]).to eq(15)
    end

    it "re-parses in full when the architecture block sits behind the vocab" do
      path = @dir / "late-arch.gguf"
      GgufWriter.write(path, {
                         "general.architecture" => "llama",
                         "tokenizer.ggml.tokens" => GgufWriter::StringArray.new(Array.new(5000) { |i| "tok#{i}" }),
                         "llama.block_count" => 32,
                       })

      expect(described_class.read_metadata(path)["llama.block_count"]).to eq(32)
    end

    it "raises EOFError when a string array is truncated" do
      path = @dir / "truncated.gguf"
      GgufWriter.write(path, {
                         "general.architecture" => "llama",
                         "general.tags" => GgufWriter::StringArray.new(Array.new(64) { |i| "tag#{i}" }),
                       })
      path.write(path.read(byte_length = path.size / 2)[0, byte_length], mode: "wb")

      expect { described_class.read_metadata(path) }.to raise_error(EOFError)
    end

    it "raises when the magic bytes don't match" do
      path = @dir / "not-gguf.bin"
      path.write("nope")
      expect { described_class.read_metadata(path) }.to raise_error(ArgumentError, "not a GGUF file")
    end
  end

  describe ".moe?" do
    it "is true when expert_count is non-zero" do
      path = @dir / "moe.gguf"
      GgufWriter.write(path, { "general.architecture" => "qwen3", "qwen3.expert_count" => 128 })
      expect(described_class.moe?(path)).to be true
    end

    it "is false when expert_count is zero or absent" do
      path = @dir / "dense.gguf"
      GgufWriter.write(path, { "general.architecture" => "qwen3", "qwen3.expert_count" => 0 })
      expect(described_class.moe?(path)).to be false
    end

    it "is nil when the header carries no architecture key" do
      path = @dir / "no-arch.gguf"
      GgufWriter.write(path, { "general.name" => "mystery" })
      expect(described_class.moe?(path)).to be_nil
    end
  end

  describe ".embedding?" do
    it "is true for an encoder with causal attention off" do
      path = @dir / "bge.gguf"
      GgufWriter.write(path, { "general.architecture" => "bert", "bert.attention.causal" => 0 })
      expect(described_class.embedding?(path)).to be true
    end

    it "is true when the header carries a pooling type" do
      path = @dir / "pooled.gguf"
      GgufWriter.write(path, { "general.architecture" => "qwen3", "qwen3.pooling_type" => 1 })
      expect(described_class.embedding?(path)).to be true
    end

    it "is true for a known encoder architecture with neither key" do
      path = @dir / "jina.gguf"
      GgufWriter.write(path, { "general.architecture" => "jina-bert-v2", "jina-bert-v2.block_count" => 12 })
      expect(described_class.embedding?(path)).to be true
    end

    it "is false for a causal chat model" do
      path = @dir / "chat.gguf"
      GgufWriter.write(path, { "general.architecture" => "qwen3", "qwen3.block_count" => 48 })
      expect(described_class.embedding?(path)).to be false
    end
  end

  describe ".pooling_type" do
    it "reads the pooling type for the model's architecture" do
      path = @dir / "bge.gguf"
      GgufWriter.write(path, { "general.architecture" => "bert", "bert.pooling_type" => 2 })
      expect(described_class.pooling_type(path)).to eq(2)
    end

    it "is nil when the header carries no pooling type" do
      path = @dir / "rerank.gguf"
      GgufWriter.write(path, { "general.architecture" => "bert", "bert.block_count" => 24 })
      expect(described_class.pooling_type(path)).to be_nil
    end
  end

  describe ".block_count" do
    it "reads block_count for the model's architecture" do
      path = @dir / "moe.gguf"
      GgufWriter.write(path, { "general.architecture" => "qwen3moe", "qwen3moe.block_count" => 48 })
      expect(described_class.block_count(path)).to eq(48)
    end

    it "is nil when the header carries no architecture key" do
      path = @dir / "no-arch.gguf"
      GgufWriter.write(path, { "general.name" => "mystery" })
      expect(described_class.block_count(path)).to be_nil
    end
  end

  describe "meta: reuses a pre-read header instead of reading the file" do
    it "moe? answers from the given metadata" do
      meta = { "general.architecture" => "qwen3", "qwen3.expert_count" => 128 }
      expect(described_class.moe?(@dir / "missing.gguf", meta: meta)).to be true
    end

    it "embedding? answers from the given metadata" do
      meta = { "general.architecture" => "bert", "bert.attention.causal" => 0 }
      expect(described_class.embedding?(@dir / "missing.gguf", meta: meta)).to be true
    end

    it "pooling_type answers from the given metadata" do
      meta = { "general.architecture" => "bert", "bert.pooling_type" => 2 }
      expect(described_class.pooling_type(@dir / "missing.gguf", meta: meta)).to eq(2)
    end

    it "block_count answers from the given metadata" do
      meta = { "general.architecture" => "qwen3moe", "qwen3moe.block_count" => 48 }
      expect(described_class.block_count(@dir / "missing.gguf", meta: meta)).to eq(48)
    end
  end

  describe ".ternary_packing" do
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

      expect(described_class.ternary_packing(path)).to eq(:g128)
    end

    it "reports mainline's 64-weight packing under the same type id" do
      path = ternary_model("g64.gguf", type: 42, block_weights: 64, block_bytes: 18)

      expect(described_class.ternary_packing(path)).to eq(:g64)
    end

    it "reports a type no engine here defines as unsupported" do
      path = ternary_model("legacy.gguf", type: 142, block_weights: 128, block_bytes: 34)

      expect(described_class.ternary_packing(path)).to eq(:unsupported)
    end

    it "returns nil for a model with no ternary tensors" do
      path = @dir / "q4.gguf"
      GgufWriter.write(path, { "general.architecture" => "llama" },
                       tensors: [["blk.0.attn_q.weight", 4096, 12, 4096]])

      expect(described_class.ternary_packing(path)).to be_nil
    end
  end

  describe ".expert_bytes_per_layer" do
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

      expect(described_class.expert_bytes_per_layer(path)).to eq(6 * 1024 * 1024)
    end

    it "returns nil when no tensor is an expert tensor" do
      path = @dir / "dense.gguf"
      GgufWriter.write(path, { "general.architecture" => "llama" }, tensors: [["blk.0.ffn_up.weight", 4096]])

      expect(described_class.expert_bytes_per_layer(path)).to be_nil
    end
  end
end
