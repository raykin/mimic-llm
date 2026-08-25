require_relative "../../lib/mimic"
require "tmpdir"

RSpec.describe Mimic::EngineCli::LlamaPreset do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  def cfg
    {
      "model" => { "path" => "/m.gguf", "context_length" => 1000 },
      "llama" => { "flash_attn" => "on", "cache_type" => "q8_0", "n_slots" => 2 },
    }
  end

  def written(model_alias: "foo", chat_template: nil, mtp: false)
    described_class.new(Mimic::LlmConfig::Settings.new(cfg), model_alias: model_alias,
                                                             chat_template: chat_template, mtp: mtp)
                   .write(@dir / "llama-models.ini").read
  end

  # Regression: `version` above the first section head becomes a preset
  # literally named "default" (preset.cpp maps the empty section name to
  # COMMON_PRESET_DEFAULT_NAME), and the parser then skips `version`, so that
  # preset carries no model. The router advertises it in /v1/models and a
  # client picking it spawns a model-less child that never loads.
  it "puts version under the global [*] section, above the model's own" do
    expect(written.lines.map(&:strip).reject(&:empty?).first(3))
      .to eq(["[*]", "version = 1", "[foo]"])
  end

  # All-GPU or nothing: without this llama.cpp auto-fit silently moves tensors
  # to CPU to make an oversized ctx boot, and the PCIe traffic per ubatch costs
  # more than the run is worth. A model that doesn't fit should fail at load.
  it "pins n-gpu-layers so an oversized context fails instead of spilling to CPU" do
    expect(written).to include("n-gpu-layers = 999")
  end

  it "carries the model, context and sampling settings through" do
    text = written
    expect(text).to include("model = /m.gguf", "ctx-size = 1000", "cache-type-k = q8_0",
                            "cache-type-v = q8_0", "parallel = 2", "temp = 0.8", "top-k = 40")
  end

  it "carries the reasoning choice through as the reasoning entry" do
    expect(written).to include("reasoning = auto")
  end

  it "turns reasoning off when the choices turned it off" do
    cfg_off = cfg
    cfg_off["model"]["reasoning"] = "off"
    text = described_class.new(Mimic::LlmConfig::Settings.new(cfg_off), model_alias: "foo")
                          .write(@dir / "llama-models.ini").read

    expect(text).to include("reasoning = off")
  end

  it "names each entry through the KEYS table, not a literal in the writer" do
    stub_const("Mimic::EngineCli::LlamaPreset::KEYS", described_class::KEYS.merge(ctx: "ctx-sizeX"))

    expect(written).to include("ctx-sizeX = 1000")
  end

  it "omits the chat template line when there is no override" do
    expect(written).not_to include("chat-template-file")
  end

  it "writes the chat template line when an override is given" do
    expect(written(chat_template: "/tmp/foo.jinja")).to include("chat-template-file = /tmp/foo.jinja")
  end

  it "adds the speculative-decoding keys only when MTP is on" do
    expect(written(mtp: false)).not_to include("spec-type")
    expect(written(mtp: true)).to include("spec-type = draft-mtp", "spec-draft-n-max = 2")
  end

  # One preset file serves every model, so a re-render has to replace it
  # rather than add to it -- otherwise the model switched away from keeps its
  # section, its path and its sampler values in the file the router reads.
  it "replaces a preset left by a previous model instead of adding to it" do
    target = @dir / "llama-models.ini"
    target.write("[*]\nversion = 1\n[oldmodel]\nmodel = /old.gguf\ntemp = 0.42\n")

    text = described_class.new(Mimic::LlmConfig::Settings.new(cfg), model_alias: "foo").write(target).read

    expect(text).to include("[foo]", "model = /m.gguf")
    expect(text).not_to include("[oldmodel]", "/old.gguf", "temp = 0.42")
  end

  it "returns the path it wrote to" do
    target = @dir / "nested/llama-models.ini"
    preset = described_class.new(Mimic::LlmConfig::Settings.new(cfg), model_alias: "foo")

    expect(preset.write(target)).to eq(target)
    expect(target).to exist
  end

  describe "auditing against the binary's flag surface" do
    # PrismML's fork has no --reasoning-effort, and the router rejects the
    # whole preset file over one key it does not recognize, taking the model
    # with it.
    let(:without_reasoning_effort) do
      instance_double(Mimic::EngineCli::BinaryOptions).tap do |options|
        allow(options).to receive(:supports?) { |name| name != "reasoning-effort" }
      end
    end

    def audited
      described_class.new(Mimic::LlmConfig::Settings.new(cfg), model_alias: "foo",
                                                               options: without_reasoning_effort)
    end

    it "leaves out a key the binary does not carry" do
      preset = audited
      text = preset.write(@dir / "llama-models.ini").read

      expect(text).not_to include("reasoning-effort")
      expect(text).to include("reasoning = auto", "model = /m.gguf")
      expect(preset.dropped).to eq(["reasoning-effort"])
    end

    it "audits the sampler keys too" do
      options = instance_double(Mimic::EngineCli::BinaryOptions)
      allow(options).to receive(:supports?) { |name| name != "top-k" }
      preset = described_class.new(Mimic::LlmConfig::Settings.new(cfg), model_alias: "foo", options: options)

      text = preset.write(@dir / "llama-models.ini").read

      expect(text).not_to include("top-k")
      expect(text).to include("temp = 0.8")
      expect(preset.dropped).to eq(["top-k"])
    end

    it "writes every key when there is no binary to audit against" do
      preset = described_class.new(Mimic::LlmConfig::Settings.new(cfg), model_alias: "foo")

      expect(preset.write(@dir / "llama-models.ini").read).to include("reasoning-effort = medium")
      expect(preset.dropped).to be_empty
    end
  end
end
