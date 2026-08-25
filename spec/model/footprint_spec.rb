require_relative "../../lib/mimic"
require_relative "../support/gguf_writer"
require "tmpdir"

RSpec.describe Mimic::Model::Footprint do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  def model_path(name = "model.gguf", **extra)
    path = @dir / name
    GgufWriter.write(path, {
                       "general.architecture" => "llama",
                       "llama.block_count" => 1,
                       "llama.attention.head_count_kv" => 1,
                       "llama.attention.key_length" => 1,
                     }.merge(extra))
    path
  end

  def footprint(path, ctx: 100, cache_type: "q8_0", compute_mib: nil)
    Mimic::Model.new(path).footprint(ctx, cache_type, compute_mib: compute_mib)
  end

  describe "#measurable?" do
    it "is true once the header parses and the card answers" do
      allow(Mimic::Util::Host).to receive(:gpu_total_mib).and_return(24_000)

      expect(footprint(model_path)).to be_measurable
    end

    it "is false when the GPU can't be queried" do
      allow(Mimic::Util::Host).to receive(:gpu_total_mib).and_return(nil)

      expect(footprint(model_path)).not_to be_measurable
    end

    it "is false when the model file is not a GGUF" do
      path = @dir / "not-gguf.bin"
      path.write("nope")
      allow(Mimic::Util::Host).to receive(:gpu_total_mib).and_return(24_000)

      expect(footprint(path)).not_to be_measurable
    end

    it "is false when the header carries no KV shape" do
      path = @dir / "shapeless.gguf"
      GgufWriter.write(path, { "general.architecture" => "llama", "llama.block_count" => 1 })
      allow(Mimic::Util::Host).to receive(:gpu_total_mib).and_return(24_000)

      expect(footprint(path)).not_to be_measurable
    end
  end

  describe "the estimate" do
    before { allow(Mimic::Util::Host).to receive(:gpu_total_mib).and_return(24_000) }

    it "flags a context that fits within budget" do
      est = footprint(model_path)

      expect(est.fits?).to be true
      expect(est.total_mib).to eq(24_000)
    end

    # A vision model's projector is loaded onto the GPU with --mmproj, so a
    # budget that only counts the decoder is short by its whole size -- 1.7 GB
    # for Ornith's mmproj-F32.gguf.
    it "counts the projector that loads beside the model" do
      path = model_path
      alone = footprint(path)

      GgufWriter.write(@dir / "mmproj-F32.gguf", { "general.type" => "mmproj" },
                       tensors: [["data", 3 * 1024 * 1024]])
      paired = footprint(path)

      expect(paired.weights_mib).to be_within(0.01).of(alone.weights_mib + 3)
      expect(paired.max_ctx).to be < alone.max_ctx
    end

    # The budget is what's left after the desktop reserve, and the estimate has
    # to carry the compute-buffer headroom -- a ctx that only fits by ignoring
    # either one loads and then dies once the KV cache fills.
    it "subtracts the desktop reserve and the compute headroom from the budget" do
      est = footprint(model_path)

      expect(est.budget_mib).to eq(24_000 - described_class::DESKTOP_RESERVE_MIB)
      expect(est.need_mib).to be > described_class.compute_default(24_000)
    end

    # The default is a flat guess tuned to one model at one context. A launch
    # that measured the real cost passes it in, and the guess steps aside.
    it "prefers a measured compute cost over the default" do
      path = model_path
      guessed = footprint(path)
      measured = footprint(path, compute_mib: 512)

      expect(guessed.need_mib - measured.need_mib)
        .to be_within(0.01).of(described_class.compute_default(24_000) - 512)
      expect(measured.max_ctx).to be > guessed.max_ctx
    end

    it "is all nil when nothing can be measured" do
      allow(Mimic::Util::Host).to receive(:gpu_total_mib).and_return(nil)
      est = footprint(model_path)

      expect(est.need_mib).to be_nil
      expect(est.budget_mib).to be_nil
      expect(est.max_ctx).to be_nil
      expect(est.fits?).to be false
    end
  end

  describe "the KV estimate" do
    before { allow(Mimic::Util::Host).to receive(:gpu_total_mib).and_return(24_000) }

    def kv_mib_of(path, cache_type: "f16", ctx: 100)
      footprint(path, ctx: ctx, cache_type: cache_type).kv_mib
    end

    it "sizes the cache from K+V elements per token" do
      path = model_path("kv.gguf", "llama.block_count" => 32, "llama.attention.head_count_kv" => 8,
                                   "llama.attention.key_length" => 128)

      expect(kv_mib_of(path)).to be_within(0.01).of(32 * 8 * 128 * 2 * 2.0 * 100 / 1024 / 1024)
    end

    it "derives head_dim from embedding_length/head_count when key_length is absent" do
      path = @dir / "derived.gguf"
      GgufWriter.write(path, {
                         "general.architecture" => "llama",
                         "llama.block_count" => 32,
                         "llama.attention.head_count_kv" => 8,
                         "llama.attention.head_count" => 32,
                         "llama.embedding_length" => 4096,
                       })

      expect(kv_mib_of(path)).to be_within(0.01).of(32 * 8 * 128 * 2 * 2.0 * 100 / 1024 / 1024)
    end

    # Hybrid attention (Qwen3.5/Next-style): only every Nth layer keeps a cache
    # that scales with context, so ceil(10/4) = 3 layers are charged for.
    it "ceil-divides the layer count for hybrid attention models" do
      path = @dir / "hybrid.gguf"
      GgufWriter.write(path, {
                         "general.architecture" => "qwen3next",
                         "qwen3next.block_count" => 10,
                         "qwen3next.full_attention_interval" => 4,
                         "qwen3next.attention.head_count_kv" => 2,
                         "qwen3next.attention.key_length" => 64,
                       })

      expect(kv_mib_of(path)).to be_within(0.01).of(3 * 2 * 64 * 2 * 2.0 * 100 / 1024 / 1024)
    end

    it "charges a quantised cache less per token than f16" do
      path = model_path("quant.gguf", "llama.block_count" => 32, "llama.attention.head_count_kv" => 8,
                                      "llama.attention.key_length" => 128)

      expect(kv_mib_of(path, cache_type: "q4_0")).to be < kv_mib_of(path, cache_type: "f16")
    end
  end

  describe "#compute_default" do
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

    it "budgets a 12 GiB card with the smaller guard, not the 3090's" do
      allow(Mimic::Util::Host).to receive(:gpu_total_mib).and_return(12_288)
      est = footprint(model_path)

      expect(est.need_mib - est.weights_mib - est.kv_mib).to be_within(0.01).of(1024)
    end
  end

  describe "#measured_overhead_mib" do
    before { allow(Mimic::Util::Host).to receive(:gpu_total_mib).and_return(24_000) }

    it "reports what the process holds beyond the weights and KV estimate" do
      est = footprint(model_path, compute_mib: 0)
      allow(Mimic::Util::Host).to receive(:gpu_process_mib).with([42]).and_return(est.need_mib.round + 700)

      expect(est.measured_overhead_mib(pids: [42])).to eq(700)
    end

    it "reports nothing when no listed process is on the GPU" do
      allow(Mimic::Util::Host).to receive(:gpu_process_mib).and_return(nil)

      expect(footprint(model_path, compute_mib: 0).measured_overhead_mib(pids: [42])).to be_nil
    end

    # An engine that spilled experts to CPU holds less VRAM than the estimate
    # assumed, and a negative or zero overhead is not a measurement of the
    # compute buffer -- storing it would under-budget every later launch.
    it "reports nothing when the process holds less than the estimate" do
      est = footprint(model_path, compute_mib: 0)
      allow(Mimic::Util::Host).to receive(:gpu_process_mib).and_return(est.need_mib.round - 10)

      expect(est.measured_overhead_mib(pids: [42])).to be_nil
    end

    it "reports nothing when the estimate itself cannot be computed" do
      allow(Mimic::Util::Host).to receive_messages(gpu_total_mib: nil, gpu_process_mib: 5000)

      expect(footprint(model_path, compute_mib: 0).measured_overhead_mib(pids: [42])).to be_nil
    end
  end

  describe "#layers_to_offload" do
    before { allow(Mimic::Util::Host).to receive(:gpu_total_mib).and_return(24_000) }

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

    # The deficit is the footprint's own: a ctx whose need overruns the budget.
    def over_committed(path, deficit_mib:)
      est = footprint(path, compute_mib: 0)
      allow(est).to receive_messages(need_mib: 1000.0 + deficit_mib, budget_mib: 1000.0)
      est
    end

    it "offloads just enough layers to cover the deficit" do
      est = over_committed(moe_model(per_layer_mib: 8), deficit_mib: 20)

      expect(est.layers_to_offload(ceiling: 28)).to eq(3)
    end

    it "offloads nothing when there is no deficit" do
      est = over_committed(moe_model, deficit_mib: 0)

      expect(est.layers_to_offload(ceiling: 28)).to eq(0)
    end

    it "gives up when the deficit needs more layers than the ceiling allows" do
      est = over_committed(moe_model(per_layer_mib: 8, layers: 4), deficit_mib: 500)

      expect(est.layers_to_offload(ceiling: 28)).to be_nil
    end

    it "returns nil for a dense model, which has no experts to move" do
      path = @dir / "dense.gguf"
      GgufWriter.write(path, {
                         "general.architecture" => "llama",
                         "llama.block_count" => 4,
                         "llama.attention.head_count_kv" => 1,
                         "llama.attention.key_length" => 1,
                       }, tensors: [["blk.0.ffn_up.weight", 1024]])

      expect(over_committed(path, deficit_mib: 10).layers_to_offload(ceiling: 28)).to be_nil
    end

    it "returns nil when nothing can be measured" do
      allow(Mimic::Util::Host).to receive(:gpu_total_mib).and_return(nil)

      expect(footprint(moe_model).layers_to_offload(ceiling: 28)).to be_nil
    end
  end
end
