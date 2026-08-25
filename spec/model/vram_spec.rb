require_relative "../../lib/mimic"
require_relative "../support/gguf_writer"
require "tmpdir"

RSpec.describe Mimic::Model::Vram do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
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

  describe ".compute_default" do
    it "reserves 2 GiB of VRAM for the desktop" do
      expect(described_class::DESKTOP_RESERVE_MIB).to eq(2048)
    end

    # The guess is a guard, not a measurement -- the real buffer tracks ubatch
    # and vocab, not card size. Holding 2 GiB back is 8% of a 3090 but 17% of a
    # 12 GiB 3060, so the guard scales with the card it has to leave room on.
    it "scales the compute guard with the card, between a floor and a ceiling" do
      expect(described_class.compute_default(12_288)).to eq(1024)
      expect(described_class.compute_default(24_000)).to eq(1440)
      expect(described_class.compute_default(80_000)).to eq(2048)
    end
  end

  describe ".measured_overhead_mib" do
    def model
      path = @dir / "model.gguf"
      GgufWriter.write(path, {
                         "general.architecture" => "llama",
                         "llama.block_count" => 1,
                         "llama.attention.head_count_kv" => 1,
                         "llama.attention.key_length" => 1,
                       })
      path
    end

    it "reports what the process holds beyond the weights and KV estimate" do
      path = model
      baseline = Mimic::Model.new(path).preflight(100, "q8_0", compute_mib: 0)
      allow(described_class).to receive(:gpu_total_mib).and_return(24_000)
      allow(described_class).to receive(:gpu_process_mib).with([42]).and_return(baseline[:need_mib].round + 700)

      expect(described_class.measured_overhead_mib(path, 100, "q8_0", pids: [42])).to eq(700)
    end

    it "reports nothing when no listed process is on the GPU" do
      allow(described_class).to receive(:gpu_total_mib).and_return(24_000)
      allow(described_class).to receive(:gpu_process_mib).and_return(nil)

      expect(described_class.measured_overhead_mib(model, 100, "q8_0", pids: [42])).to be_nil
    end

    # An engine that spilled experts to CPU holds less VRAM than the estimate
    # assumed, and a negative or zero overhead is not a measurement of the
    # compute buffer -- storing it would under-budget every later launch.
    it "reports nothing when the process holds less than the estimate" do
      path = model
      baseline = Mimic::Model.new(path).preflight(100, "q8_0", compute_mib: 0)
      allow(described_class).to receive(:gpu_total_mib).and_return(24_000)
      allow(described_class).to receive(:gpu_process_mib).and_return(baseline[:need_mib].round - 10)

      expect(described_class.measured_overhead_mib(path, 100, "q8_0", pids: [42])).to be_nil
    end

    it "reports nothing when the estimate itself cannot be computed" do
      allow(described_class).to receive(:gpu_total_mib).and_return(nil)

      expect(described_class.measured_overhead_mib(model, 100, "q8_0", pids: [42])).to be_nil
    end
  end

  describe ".layers_to_offload" do
    def moe_model(per_layer_mib: 8, layers: 4)
      path = @dir / "moe.gguf"
      tensors = (0...layers).map { |i| ["blk.#{i}.ffn_up_exps.weight", per_layer_mib * 1024 * 1024] }
      GgufWriter.write(path, {
                         "general.architecture" => "llama",
                         "llama.block_count" => layers,
                         "llama.expert_count" => 8,
                         "llama.attention.head_count_kv" => 1,
                         "llama.attention.key_length" => 1,
                       }, tensors: tensors)
      path
    end

    it "offloads just enough layers to cover the deficit" do
      path = moe_model(per_layer_mib: 8)

      expect(described_class.layers_to_offload(path, deficit_mib: 20, ceiling: 28)).to eq(3)
    end

    it "offloads nothing when there is no deficit" do
      expect(described_class.layers_to_offload(moe_model, deficit_mib: 0, ceiling: 28)).to eq(0)
    end

    it "gives up when the deficit needs more layers than the ceiling allows" do
      path = moe_model(per_layer_mib: 8, layers: 4)

      expect(described_class.layers_to_offload(path, deficit_mib: 500, ceiling: 28)).to be_nil
    end

    it "returns nil for a dense model, which has no experts to move" do
      path = @dir / "dense.gguf"
      GgufWriter.write(path, { "general.architecture" => "llama", "llama.block_count" => 4 },
                       tensors: [["blk.0.ffn_up.weight", 1024]])

      expect(described_class.layers_to_offload(path, deficit_mib: 10, ceiling: 28)).to be_nil
    end
  end
end
