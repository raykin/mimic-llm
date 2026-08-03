require_relative "../../lib/mimic"
require "tmpdir"
require "fileutils"

RSpec.describe Mimic::Services::Clients do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  it "inserts a new crush model entry and updates ctx" do
    path = @dir / "crush.json"
    path.write(JSON.generate({ "providers" => { "llamacpp" => {} } }))
    stub_const("Mimic::Services::Clients::CRUSH_CONFIG", path)

    expect(described_class.sync_crush("my-model", 128_000)).to be true
    data = JSON.parse(path.read)
    entry = data["providers"]["llamacpp"]["models"].first
    expect(entry["id"]).to eq("my-model")
    expect(entry["context_window"]).to eq(128_000)
  end

  it "returns false when the client has no llamacpp provider block" do
    path = @dir / "crush.json"
    path.write(JSON.generate({ "providers" => {} }))
    stub_const("Mimic::Services::Clients::CRUSH_CONFIG", path)

    expect(described_class.sync_crush("my-model", 128_000)).to be false
  end

  it "returns false when the client config is missing entirely" do
    stub_const("Mimic::Services::Clients::CRUSH_CONFIG", @dir / "missing.json")
    expect(described_class.sync_crush("my-model", 128_000)).to be false
  end

  it "returns false instead of raising when the client config is unreadable" do
    path = @dir / "crush.json"
    path.write(JSON.generate({ "providers" => { "llamacpp" => {} } }))
    path.chmod(0o000)
    stub_const("Mimic::Services::Clients::CRUSH_CONFIG", path)

    expect(described_class.sync_crush("my-model", 128_000)).to be false
  end

  it "syncs goose when its config carries a date scalar" do
    goose = @dir / "config.yaml"
    goose.write("GOOSE_PROVIDER: openai\nlast_used: 2026-07-28\n")
    stub_const("Mimic::Services::Clients::GOOSE_CONFIG", goose)
    stub_const("Mimic::Services::Clients::GOOSE_PROVIDER_FILE", @dir / "custom_providers/llamacpp.json")

    expect(described_class.sync_goose("my-model", 999, "http://127.0.0.1:8080")).to be true
    expect(goose.read).to include("GOOSE_MODEL: my-model")
  end

  it "updates an existing pi model entry in place instead of duplicating" do
    path = @dir / "models.json"
    path.write(JSON.generate({
                                "providers" => { "llamacpp" => { "models" => [{ "id" => "my-model", "contextWindow" => 1 }] } },
                              }))
    stub_const("Mimic::Services::Clients::PI_MODELS", path)
    stub_const("Mimic::Services::Clients::PI_SETTINGS", @dir / "settings-missing.json")

    expect(described_class.sync_pi("my-model", 999)).to be true
    models = JSON.parse(path.read)["providers"]["llamacpp"]["models"]
    expect(models.length).to eq(1)
    expect(models.first["contextWindow"]).to eq(999)
  end

  describe ".sync" do
    it "derives alias and context from Settings and syncs only the clients with a config present" do
      path = @dir / "crush.json"
      path.write(JSON.generate({ "providers" => { "llamacpp" => {} } }))
      stub_const("Mimic::Services::Clients::CRUSH_CONFIG", path)
      stub_const("Mimic::Services::Clients::OPENCODE_CONFIG", @dir / "missing-opencode.jsonc")
      stub_const("Mimic::Services::Clients::PI_MODELS", @dir / "missing-pi.json")
      stub_const("Mimic::Services::Clients::GOOSE_CONFIG", @dir / "missing-goose.yaml")
      stub_const("Mimic::Services::Hermes::HERMES_CONFIG_PATH", @dir / "no-hermes-dir/config.yaml")

      settings = Mimic::LlmConfig::Settings.new(
        "model" => { "path" => "/models/my-model.gguf", "context_length" => 128_000 },
        "llama" => { "port" => 8080 },
      )

      expect(described_class.sync(settings)).to eq(["crush"])
      entry = JSON.parse(path.read)["providers"]["llamacpp"]["models"].first
      expect(entry["id"]).to eq("my-model")
      expect(entry["context_window"]).to eq(128_000)
    end
  end

  describe "opencode comment preservation" do
    let(:jsonc) do
      <<~JSONC
        // user note: keep me
        {
          "provider": { "llamacpp": { "models": {} } }
        }
      JSONC
    end

    it "refuses to rewrite an opencode.jsonc that carries comments" do
      path = @dir / "opencode.jsonc"
      path.write(jsonc)
      stub_const("Mimic::Services::Clients::OPENCODE_CONFIG", path)

      expect { expect(described_class.sync_opencode("my-model", 128_000)).to be false }
        .to output(/comment/i).to_stderr
      expect(path.read).to eq(jsonc)
    end

    it "still syncs a comment-free opencode.jsonc" do
      path = @dir / "opencode.jsonc"
      path.write(JSON.generate({ "provider" => { "llamacpp" => { "models" => {} } } }))
      stub_const("Mimic::Services::Clients::OPENCODE_CONFIG", path)

      expect(described_class.sync_opencode("my-model", 128_000)).to be true
      data = JSON.parse(path.read)
      expect(data["model"]).to eq("llamacpp/my-model")
      expect(data["provider"]["llamacpp"]["models"]["my-model"]["limit"]["context"]).to eq(128_000)
    end
  end
end
