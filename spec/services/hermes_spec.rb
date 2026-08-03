require_relative "../../lib/mimic"
require "tmpdir"
require "fileutils"

RSpec.describe Mimic::Services::Hermes do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  let(:cfg) do
    {
      "model" => { "path" => "/models/Ornith-1.0-35B-UD-IQ4_NL.gguf", "context_length" => 123_456 },
      "llama" => { "host" => "0.0.0.0", "port" => 8080 },
    }
  end
  let(:settings) { Mimic::LlmConfig::Settings.new(cfg) }

  def stub_config_path(path)
    stub_const("Mimic::Services::Hermes::HERMES_CONFIG_PATH", path)
  end

  describe ".find_binary" do
    it "prefers the venv binary when present" do
      venv_binary = @dir / "venv/bin/hermes"
      venv_binary.dirname.mkpath
      FileUtils.touch(venv_binary)
      stub_const("Mimic::Config::HERMES_VENV", @dir / "venv")

      expect(described_class.find_binary).to eq(venv_binary.to_s)
    end

    it "falls back to PATH when the venv binary is absent" do
      stub_const("Mimic::Config::HERMES_VENV", @dir / "no-venv")
      allow(Mimic::Probes).to receive(:which).with("hermes").and_return("/usr/bin/hermes")

      expect(described_class.find_binary).to eq("/usr/bin/hermes")
    end
  end

  it "syncs a config that carries a date scalar" do
    path = @dir / "config.yaml"
    path.write("terminal:\n  timeout: 300\nlast_used: 2026-07-28\n")
    stub_config_path(path)

    expect { described_class.sync_config(settings) }.not_to raise_error
    expect(path.read).to include("last_used: 2026-07-28")
    expect(path.read).to include("default: Ornith-1.0-35B-UD")
  end

  it "preserves hermes' own keys and drops the dead model keys" do
    path = @dir / "config.yaml"
    path.write(<<~YAML)
      model:
        path: /models/old.gguf
        temperature: 0.7
        api_key: llama.cpp
      display:
        skin: sisyphus
    YAML
    stub_config_path(path)

    described_class.sync_config(settings)
    merged = Psych.safe_load(path.read)
    expect(merged["model"]).not_to have_key("path")
    expect(merged["model"]).not_to have_key("temperature")
    expect(merged["model"]["api_key"]).to eq("llama.cpp")
    expect(merged["display"]["skin"]).to eq("sisyphus")
    expect(merged["model"]["context_length"]).to eq(123_456)
  end

  it "writes a full config when none exists yet" do
    path = @dir / "nested/config.yaml"
    stub_config_path(path)

    expect(described_class.sync_config(settings)).to eq(path)
    merged = Psych.safe_load(path.read)
    expect(merged["providers"]["local-llama-cpp"]["models"]).to eq(["Ornith-1.0-35B-UD"])
    expect(merged["auxiliary"]["title_generation"]["timeout"]).to eq(15)
  end
end
