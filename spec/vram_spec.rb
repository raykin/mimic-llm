require_relative "../lib/mimic"
require "tmpdir"

# Minimal GGUF v3 writer covering only what Vram.read_metadata parses:
# magic, version, tensor count, then N key/value pairs. Types used here are
# STRING (8) and UINT32 (4), matching what the real header carries for the
# keys Vram cares about.
module GgufWriter
  UINT32 = 4
  STRING = 8
  ARRAY = 9

  # A string array value: `GgufWriter.write(path, "tokenizer.ggml.tokens" => StringArray.new(%w[a b]))`
  StringArray = Struct.new(:entries)

  module_function

  def write(path, kv)
    File.open(path, "wb") do |f|
      f.write("GGUF")
      f.write([3].pack("L<"))       # version
      f.write([0].pack("Q<"))       # tensor count
      f.write([kv.size].pack("Q<")) # kv count
      kv.each do |key, value|
        write_string(f, key)
        if value.is_a?(StringArray)
          f.write([ARRAY].pack("L<"))
          f.write([STRING].pack("L<"))
          f.write([value.entries.size].pack("Q<"))
          value.entries.each { |e| write_string(f, e) }
        elsif value.is_a?(String)
          f.write([STRING].pack("L<"))
          write_string(f, value)
        else
          f.write([UINT32].pack("L<"))
          f.write([value].pack("L<"))
        end
      end
    end
  end

  def write_string(f, s)
    f.write([s.bytesize].pack("Q<"))
    f.write(s)
  end
end

RSpec.describe Mimic::Vram do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
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

    it "is nil when the file can't be read" do
      expect(described_class.moe?(@dir / "missing.gguf")).to be_nil
    end
  end

  describe ".block_count" do
    it "reads block_count for the model's architecture" do
      path = @dir / "moe.gguf"
      GgufWriter.write(path, { "general.architecture" => "qwen3moe", "qwen3moe.block_count" => 48 })
      expect(described_class.block_count(path)).to eq(48)
    end

    it "is nil when the file can't be read" do
      expect(described_class.block_count(@dir / "missing.gguf")).to be_nil
    end
  end

  describe ".kv_elems_per_token" do
    it "computes K+V elements per token for a standard attention model" do
      meta = {
        "general.architecture" => "llama",
        "llama.block_count" => 32,
        "llama.attention.head_count_kv" => 8,
        "llama.attention.key_length" => 128,
      }
      expect(described_class.kv_elems_per_token(meta)).to eq(32 * 8 * 128 * 2)
    end

    it "derives head_dim from embedding_length/head_count when key_length is absent" do
      meta = {
        "general.architecture" => "llama",
        "llama.block_count" => 32,
        "llama.attention.head_count_kv" => 8,
        "llama.attention.head_count" => 32,
        "llama.embedding_length" => 4096,
      }
      expect(described_class.kv_elems_per_token(meta)).to eq(32 * 8 * 128 * 2)
    end

    it "ceil-divides the layer count for hybrid attention models" do
      meta = {
        "general.architecture" => "qwen3next",
        "qwen3next.block_count" => 10,
        "qwen3next.full_attention_interval" => 4,
        "qwen3next.attention.head_count_kv" => 2,
        "qwen3next.attention.key_length" => 64,
      }
      # ceil(10/4) = 3 full-attention layers
      expect(described_class.kv_elems_per_token(meta)).to eq(3 * 2 * 64 * 2)
    end

    it "returns nil when required fields are missing" do
      expect(described_class.kv_elems_per_token({ "general.architecture" => "llama" })).to be_nil
    end
  end

  describe ".preflight" do
    it "flags a context that fits within budget" do
      path = @dir / "model.gguf"
      GgufWriter.write(path, {
                          "general.architecture" => "llama",
                          "llama.block_count" => 1,
                          "llama.attention.head_count_kv" => 1,
                          "llama.attention.key_length" => 1,
                        })
      allow(described_class).to receive(:gpu_total_mib).and_return(24_000)

      est = described_class.preflight(path, 100, "q8_0")
      expect(est[:fits]).to be true
      expect(est[:total_mib]).to eq(24_000)
    end

    it "returns nil when the GPU can't be queried" do
      path = @dir / "model.gguf"
      GgufWriter.write(path, { "general.architecture" => "llama", "llama.block_count" => 1,
                                "llama.attention.head_count_kv" => 1, "llama.attention.key_length" => 1 })
      allow(described_class).to receive(:gpu_total_mib).and_return(nil)
      expect(described_class.preflight(path, 100, "q8_0")).to be_nil
    end
  end
end
