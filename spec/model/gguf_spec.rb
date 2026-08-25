require_relative "../../lib/mimic"
require_relative "../support/gguf_writer"
require "tmpdir"

RSpec.describe Mimic::Model::Gguf do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  describe "#metadata" do
    it "reads scalar and string kv pairs from a GGUF header" do
      path = @dir / "model.gguf"
      GgufWriter.write(path, { "general.architecture" => "llama", "llama.block_count" => 32 })

      meta = described_class.new(path).metadata
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

      meta = described_class.new(path).metadata
      expect(meta["llama.block_count"]).to eq(32)
      expect(meta).not_to have_key("general.tags")
    end

    it "keeps a per-layer numeric array" do
      path = @dir / "per_layer.gguf"
      GgufWriter.write(path, {
                         "general.architecture" => "gemma4",
                         "gemma4.attention.head_count_kv" => [16, 16, 4],
                         "gemma4.block_count" => 3,
                       })

      meta = described_class.new(path).metadata
      expect(meta["gemma4.attention.head_count_kv"]).to eq([16, 16, 4])
      expect(meta["gemma4.block_count"]).to eq(3)
    end

    it "skips a vocab-sized numeric array and keeps reading later keys" do
      path = @dir / "token_types.gguf"
      GgufWriter.write(path, {
                         "general.architecture" => "llama",
                         "tokenizer.ggml.token_type" => Array.new(described_class::BIG_SCALAR_ARRAY + 1, 1),
                         "llama.block_count" => 32,
                       })

      meta = described_class.new(path).metadata
      expect(meta).not_to have_key("tokenizer.ggml.token_type")
      expect(meta["llama.block_count"]).to eq(32)
    end

    it "stops at a vocab-sized string array once the architecture block is read" do
      path = @dir / "vocab.gguf"
      GgufWriter.write(path, {
                         "general.architecture" => "llama",
                         "llama.block_count" => 32,
                         "tokenizer.ggml.tokens" => GgufWriter::StringArray.new(Array.new(5000) { |i| "tok#{i}" }),
                         "general.file_type" => 15,
                       })

      meta = described_class.new(path).metadata
      expect(meta["llama.block_count"]).to eq(32)
      expect(meta).not_to have_key("general.file_type")
      expect(described_class.new(path).metadata(full: true)["general.file_type"]).to eq(15)
    end

    it "re-parses in full when the architecture block sits behind the vocab" do
      path = @dir / "late-arch.gguf"
      GgufWriter.write(path, {
                         "general.architecture" => "llama",
                         "tokenizer.ggml.tokens" => GgufWriter::StringArray.new(Array.new(5000) { |i| "tok#{i}" }),
                         "llama.block_count" => 32,
                       })

      expect(described_class.new(path).metadata["llama.block_count"]).to eq(32)
    end

    it "reads the file once and answers later calls from memory" do
      path = @dir / "memo.gguf"
      GgufWriter.write(path, { "general.architecture" => "llama", "llama.block_count" => 32 })
      gguf = described_class.new(path)
      gguf.metadata

      expect(File).not_to receive(:open)

      expect(gguf.metadata["llama.block_count"]).to eq(32)
    end

    it "keeps the two parse depths apart" do
      path = @dir / "both.gguf"
      GgufWriter.write(path, {
                         "general.architecture" => "llama",
                         "llama.block_count" => 32,
                         "tokenizer.ggml.tokens" => GgufWriter::StringArray.new(Array.new(5000) { |i| "tok#{i}" }),
                         "general.file_type" => 15,
                       })
      gguf = described_class.new(path)

      expect(gguf.metadata(full: true)).to have_key("general.file_type")
      expect(gguf.metadata).not_to have_key("general.file_type")
    end

    it "raises EOFError when a string array is truncated" do
      path = @dir / "truncated.gguf"
      GgufWriter.write(path, {
                         "general.architecture" => "llama",
                         "general.tags" => GgufWriter::StringArray.new(Array.new(64) { |i| "tag#{i}" }),
                       })
      path.write(path.read(byte_length = path.size / 2)[0, byte_length], mode: "wb")

      expect { described_class.new(path).metadata }.to raise_error(EOFError)
    end

    # A header cut mid-integer used to surface as NoMethodError on nil, which
    # only the tensor walk rescued -- Header let it through.
    it "raises EOFError when the header ends mid-value" do
      path = @dir / "stub.gguf"
      GgufWriter.write(path, { "general.architecture" => "llama", "llama.block_count" => 32 })
      path.write(path.read(6)[0, 6], mode: "wb")

      expect { described_class.new(path).metadata }.to raise_error(EOFError)
    end

    it "raises when the magic bytes don't match" do
      path = @dir / "not-gguf.bin"
      path.write("nope")

      expect { described_class.new(path).metadata }.to raise_error(ArgumentError, "not a GGUF file")
    end

    it "raises ENOENT for a file that is not there" do
      expect { described_class.new(@dir / "missing.gguf").metadata }.to raise_error(Errno::ENOENT)
    end
  end

  describe "#tensors" do
    it "reads name, element count, type and offset for each tensor" do
      path = @dir / "tensors.gguf"
      GgufWriter.write(path, { "general.architecture" => "llama" },
                       tensors: [["blk.0.attn_q.weight", 4096, 12, 1024],
                                 ["blk.0.attn_k.weight", 2048, 8, 512]])

      expect(described_class.new(path).tensors).to eq(
        [{ name: "blk.0.attn_q.weight", elements: 1024, type: 12, offset: 0 },
         { name: "blk.0.attn_k.weight", elements: 512, type: 8, offset: 4096 }]
      )
    end

    # The KV walk has to be exhaustive here: the early stop metadata takes on
    # a vocab-sized array would leave the file positioned mid-header.
    it "walks past a vocab-sized array to reach the tensor info block" do
      path = @dir / "vocab-tensors.gguf"
      GgufWriter.write(path, {
                         "general.architecture" => "llama",
                         "tokenizer.ggml.tokens" => GgufWriter::StringArray.new(Array.new(5000) { |i| "tok#{i}" }),
                       },
                       tensors: [["blk.0.attn_q.weight", 4096, 12, 1024]])

      expect(described_class.new(path).tensors.map { |t| t[:name] }).to eq(["blk.0.attn_q.weight"])
    end

    it "raises rather than returning nil for a file that is not a GGUF" do
      path = @dir / "nope.bin"
      path.write("nope")

      expect { described_class.new(path).tensors }.to raise_error(ArgumentError, "not a GGUF file")
    end
  end

  describe "#tensor_sizes" do
    # Offsets are relative to the start of the data block, so the last tensor
    # is bounded by the tail of the file rather than by a following offset.
    it "sizes each tensor from the gap to the next one, and the last from the file tail" do
      path = @dir / "sizes.gguf"
      GgufWriter.write(path, { "general.architecture" => "llama" },
                       tensors: [["blk.0.attn_q.weight", 4096], ["blk.0.attn_k.weight", 2048]])

      expect(described_class.new(path).tensor_sizes).to eq("blk.0.attn_q.weight" => 4096,
                                                           "blk.0.attn_k.weight" => 2048)
    end
  end
end
