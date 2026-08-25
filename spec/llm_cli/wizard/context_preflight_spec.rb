require_relative "../../../lib/mimic"
require_relative "../../../lib/mimic/llm_cli/wizard/context_preflight"
require "tmpdir"

RSpec.describe Mimic::LlmCli::Wizard::ContextPreflight do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  before do
    stub_const("Mimic::LlmConfig::MODEL_COMPUTE_PATH", @dir / "model-compute.json")
    stub_const("Mimic::Model::Memory::N_CPU_MOE_PATH", @dir / "ik-n-cpu-moe.json")
  end

  def preflight(cfg = base_cfg, prompt: instance_double(Mimic::Ui::Prompt))
    described_class.new(Mimic::LlmConfig::Settings.new(cfg), prompt: prompt)
  end

  def base_cfg = { "model" => { "path" => "/m.gguf", "context_length" => 60_000 },
                   "llama" => { "cache_type" => "q8_0" } }

  def ik_cfg = { "model" => { "path" => "/m.gguf", "context_length" => 60_000 },
                 "llama" => { "cache_type" => "q8_0", "engine" => "ik_llama.cpp" } }

  def footprint_double(**values)
    instance_double(Mimic::Model::Footprint, **{ measurable?: true }.merge(values))
  end

  it "accepts without prompting when the estimate can't be computed" do
    allow_any_instance_of(Mimic::Model).to receive(:footprint).and_return(footprint_double(measurable?: false))

    expect(preflight.ok?).to be(true)
  end

  it "accepts and reports the headroom when the estimate fits" do
    allow_any_instance_of(Mimic::Model).to receive(:footprint)
      .and_return(footprint_double(fits?: true, need_mib: 1000.0, total_mib: 24_000, max_ctx: 5000))

    result = nil
    expect { result = preflight.ok? }.to output(/VRAM ok -- needs ~1.0 GB of 23.4 GB \(fits to ~5,000 tok\)/).to_stdout
    expect(result).to be(true)
  end

  # A past launch measured what this model really costs beyond weights+KV;
  # the preflight budgets against that instead of Footprint.compute_default.
  it "passes the measured compute cost to the estimate when one was recorded" do
    Mimic::Model.new("/m.gguf").memory.remember_compute(60_000, "q8_0", 1712)
    expect_any_instance_of(Mimic::Model).to receive(:footprint)
      .with(60_000, "q8_0", compute_mib: 1712)
      .and_return(footprint_double(fits?: true, need_mib: 1000.0, total_mib: 24_000, max_ctx: 5000))

    expect { preflight.ok? }.to output(/VRAM ok/).to_stdout
  end

  # A MoE model has a lever the warning never offered: move experts to the
  # CPU until the rest fits. Only ik_llama takes --n-cpu-moe.
  it "offloads MoE experts instead of warning when that closes the gap" do
    allow_any_instance_of(Mimic::Model).to receive(:footprint).and_return(
      footprint_double(fits?: false, need_mib: 23_100.0, weights_mib: 19_000.0, kv_mib: 2_000.0,
                       budget_mib: 22_528.0, total_mib: 24_576, max_ctx: 140_000, layers_to_offload: 2),
    )

    result = nil
    expect { result = preflight(ik_cfg).ok? }.to output(/offloading 2 layers of MoE experts to CPU/).to_stdout
    expect(result).to be(true)
    expect(Mimic::Model.new("/m.gguf").memory.n_cpu_moe).to eq(2)
  end

  it "caps the offload at the model's layer count" do
    allow_any_instance_of(Mimic::Model::Header).to receive(:block_count).and_return(12)
    estimate = footprint_double(fits?: false, need_mib: 23_100.0, weights_mib: 19_000.0, kv_mib: 2_000.0,
                                budget_mib: 22_528.0, total_mib: 24_576, max_ctx: 140_000, layers_to_offload: 2)
    allow_any_instance_of(Mimic::Model).to receive(:footprint).and_return(estimate)

    expect { preflight(ik_cfg).ok? }.to output.to_stdout

    expect(estimate).to have_received(:layers_to_offload).with(ceiling: 12)
  end

  it "caps the offload at the engine's own ceiling when the model has more layers" do
    allow_any_instance_of(Mimic::Model::Header).to receive(:block_count).and_return(100)
    estimate = footprint_double(fits?: false, need_mib: 23_100.0, weights_mib: 19_000.0, kv_mib: 2_000.0,
                                budget_mib: 22_528.0, total_mib: 24_576, max_ctx: 140_000, layers_to_offload: 2)
    allow_any_instance_of(Mimic::Model).to receive(:footprint).and_return(estimate)

    expect { preflight(ik_cfg).ok? }.to output.to_stdout

    expect(estimate).to have_received(:layers_to_offload).with(ceiling: Mimic::Engine::IkLlama::CPU_MOE_MAX)
  end

  it "warns and asks when offloading cannot close the gap" do
    allow_any_instance_of(Mimic::Model).to receive(:footprint).and_return(
      footprint_double(fits?: false, need_mib: 40_000.0, weights_mib: 30_000.0, kv_mib: 8_000.0,
                       budget_mib: 22_528.0, total_mib: 24_576, max_ctx: 500, layers_to_offload: nil),
    )
    prompt = instance_double(Mimic::Ui::Prompt, yes?: false)

    result = nil
    expect { result = preflight(ik_cfg, prompt: prompt).ok? }
      .to output(/won't fully fit VRAM.*Needs ~39.1 GB \(weights 29.3 \+ KV 7.8 \+ compute\), budget ~22.0 GB/m).to_stdout
    expect(result).to be(false)
  end

  it "warns rather than offloading on llama.cpp, which is all-GPU by design" do
    over = footprint_double(fits?: false, need_mib: 23_100.0, weights_mib: 19_000.0, kv_mib: 2_000.0,
                            budget_mib: 22_528.0, total_mib: 24_576, max_ctx: 140_000, layers_to_offload: 2)
    allow_any_instance_of(Mimic::Model).to receive(:footprint).and_return(over)
    prompt = instance_double(Mimic::Ui::Prompt, yes?: false)

    expect { preflight(base_cfg, prompt: prompt).ok? }.to output(/won't fully fit VRAM/).to_stdout
    expect(over).not_to have_received(:layers_to_offload)
  end

  # The wizard keeps one preflight across the re-pick loop, so a second ask
  # has to be estimated against the context just picked, not the first one.
  it "re-estimates against the current context on every ask" do
    settings = Mimic::LlmConfig::Settings.new(base_cfg)
    model = settings.model.file
    allow(model).to receive(:footprint).and_return(footprint_double(measurable?: false))
    instance = described_class.new(settings, prompt: instance_double(Mimic::Ui::Prompt))

    instance.ok?
    settings.model.context_length = 131_072
    instance.ok?

    expect(model).to have_received(:footprint).with(131_072, "q8_0", any_args)
  end

  it "accepts an over-committed context the user confirms" do
    allow_any_instance_of(Mimic::Model).to receive(:footprint).and_return(
      footprint_double(fits?: false, need_mib: 40_000.0, weights_mib: 30_000.0, kv_mib: 8_000.0,
                       budget_mib: 22_528.0, total_mib: 24_576, max_ctx: 500, layers_to_offload: nil),
    )
    prompt = instance_double(Mimic::Ui::Prompt, yes?: true)

    result = nil
    expect { result = preflight(ik_cfg, prompt: prompt).ok? }.to output(/won't fully fit/).to_stdout
    expect(result).to be(true)
  end
end
