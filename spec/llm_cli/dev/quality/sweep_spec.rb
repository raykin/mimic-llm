require_relative "../../../../lib/mimic"
require_relative "../../../../lib/mimic/llm_cli/dev/quality/sweep"

RSpec.describe Mimic::LlmCli::Dev::Quality::Sweep do
  subject(:sweep) { described_class.new(config, harness: harness, models: models) }

  let(:config) do
    Mimic::LlmConfig::Settings.new(
      "model" => { "path" => "/models/original.gguf", "context_length" => 140_032 },
      "llama" => { "engine" => "llama.cpp", "host" => "127.0.0.1", "port" => 8080 }
    )
  end
  let(:harness) { instance_double(Mimic::LlmCli::Dev::Quality::Harness, run: true) }
  let(:models) { [model("/models/a.gguf", "ik_llama.cpp"), model("/models/b.gguf", nil)] }

  # The two engines take different keywords -- ik_llama.cpp alone accepts
  # n_cpu_moe -- so one verified double for both would accept a call the real
  # object rejects. Registry dispatches on the engine the sweep just set, the
  # way the real one does, and both doubles record into `starts`.
  let(:starts) { [] }
  let(:ik_engine) { instance_double(Mimic::Engine::IkLlama, render_preset: nil) }
  let(:llama_engine) { instance_double(Mimic::Engine::Llama, render_preset: nil) }

  def model(path, remembered_engine)
    memory = instance_double(Mimic::Model::Memory, engine: remembered_engine)
    instance_double(Mimic::Model, path: Pathname.new(path), memory: memory, moe?: false)
  end

  before do
    [ik_engine, llama_engine].each do |double|
      allow(double).to receive(:start) do |**options|
        starts << { engine: config.llama.engine, ctx: config.model.context_length, **options }
        Mimic::Result.ok("ready")
      end
    end
    allow(Mimic::EngineCli::Registry).to receive(:for) { |cfg| cfg.llama.ik? ? ik_engine : llama_engine }
    allow(Mimic::Engine::ServerProcess).to receive(:chat)
      .and_return(instance_double(Mimic::Engine::ServerProcess, stop: true, pids: []))
    allow(Mimic::Engine::ServerProcess).to receive(:embed)
      .and_return(instance_double(Mimic::Engine::ServerProcess, pids: []))
  end

  # The whole reason this command exists rather than a shell loop over `llm
  # setup`: a quality sweep must not become the thing that rewrites the setup
  # it is measuring.
  describe "the caller's saved setup" do
    it "never writes config.yaml" do
      expect(config).not_to receive(:save)

      sweep.run
    end

    it "starts every engine with remember: false, so no run is recorded as the model's last good ctx" do
      sweep.run

      expect(starts.map { |start| start[:remember] }).to eq([false, false])
    end

    it "restores the configured model's preset once the sweep is over" do
      allow(Mimic::LlmConfig).to receive(:load).and_return(config)

      sweep.run

      expect(llama_engine).to have_received(:render_preset)
    end
  end

  describe "the served context" do
    it "locks every model to the sweep context rather than its remembered one" do
      sweep.run

      expect(starts.map { |start| start[:ctx] }).to eq([described_class::CONTEXT, described_class::CONTEXT])
    end
  end

  # Every model fits fully resident at this context, so a sweep run has no
  # reason to put experts on the CPU -- and a score taken at whatever offload
  # one model happens to have cached is not comparable with one taken at zero.
  describe "the MoE offload" do
    it "forces ik_llama.cpp to zero rather than letting the cache or the preflight choose" do
      sweep.run

      expect(starts.first).to include(engine: "ik_llama.cpp", n_cpu_moe: 0)
    end

    # llama.cpp's start takes no such keyword, so passing one raises.
    it "passes no offload keyword to llama.cpp" do
      sweep.run

      expect(starts.last[:engine]).to eq("llama.cpp")
      expect(starts.last).not_to have_key(:n_cpu_moe)
    end
  end

  describe "engine selection" do
    it "serves a model on the engine its verdict names" do
      sweep.run

      expect(starts.first[:engine]).to eq("ik_llama.cpp")
    end

    # No verdict is not "use whatever the config had" -- the config's engine
    # belongs to the configured model, not to this one.
    it "falls back to llama.cpp for a dense model with no verdict" do
      sweep.run

      expect(starts.last[:engine]).to eq("llama.cpp")
    end

    it "falls back to ik_llama.cpp for an unjudged MoE I-quant, which mainline has no kernels for" do
      memory = instance_double(Mimic::Model::Memory, engine: nil, iquant?: true)
      moe = instance_double(Mimic::Model, path: Pathname.new("/models/moe.gguf"), memory: memory, moe?: true)

      expect(described_class.engine_for(moe)).to eq("ik_llama.cpp")
    end
  end

  describe "#run" do
    # The alias stops at the quant marker, so two quants of one model share it
    # -- the harness is handed the stem so its two runs stay distinguishable.
    it "hands each served model to the harness by GGUF stem and reports how many ran" do
      expect(harness).to receive(:run).with("a").ordered
      expect(harness).to receive(:run).with("b").ordered

      expect(sweep.run).to eq(2)
    end

    # One model that will not load is not a reason to abandon the other nine
    # in an unattended sweep.
    it "skips a model that fails to start and carries on with the rest" do
      allow(ik_engine).to receive(:start).and_return(Mimic::Result.error("boom"))

      expect(harness).to receive(:run).with("b").once

      expect { expect(sweep.run).to eq(1) }.to output(/boom/).to_stdout
    end
  end
end
