require_relative "../lib/mimic"
require "tmpdir"

RSpec.describe Mimic::Client do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  def settings(port: 8080)
    Mimic::LlmConfig::Settings.new(
      "model" => { "path" => "/models/my-model.gguf", "context_length" => 128_000 },
      "llama" => { "port" => port },
    )
  end

  describe ".sync" do
    it "derives alias and context from Settings and syncs only the clients with a config present" do
      path = @dir / "crush.json"
      path.write(JSON.generate({ "providers" => { "llamacpp" => {} } }))
      stub_const("Mimic::Client::Crush::CONFIG_PATH", path)
      stub_const("Mimic::Client::Opencode::CONFIG_PATH", @dir / "missing-opencode.jsonc")
      stub_const("Mimic::Client::Pi::CONFIG_PATH", @dir / "missing-pi.json")
      stub_const("Mimic::Client::Goose::CONFIG_PATH", @dir / "missing-goose.yaml")
      stub_const("Mimic::Client::Goose::PROVIDER_FILE", @dir / "custom_providers/llamacpp.json")
      stub_const("Mimic::Agent::Hermes::CONFIG_PATH", @dir / "no-hermes-dir/config.yaml")

      expect(described_class.sync(settings)).to eq(["crush"])
      entry = JSON.parse(path.read)["providers"]["llamacpp"]["models"].first
      expect(entry["id"]).to eq("my-model")
      expect(entry["context_window"]).to eq(128_000)
    end
  end

  describe "the roster" do
    it "names every client in sync order" do
      expect(described_class::CLIENTS).to eq(%w[hermes goose crush opencode pi])
    end
  end
end

RSpec.describe Mimic::Client::Crush do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  subject(:client) do
    described_class.new(Mimic::LlmConfig::Settings.new(
                          "model" => { "path" => "/models/my-model.gguf", "context_length" => 128_000 },
                          "llama" => { "port" => 8080 },
                        ))
  end

  it "inserts a new model entry and updates ctx" do
    path = @dir / "crush.json"
    path.write(JSON.generate({ "providers" => { "llamacpp" => {} } }))
    stub_const("#{described_class}::CONFIG_PATH", path)

    expect(client.sync).to be true
    entry = JSON.parse(path.read)["providers"]["llamacpp"]["models"].first
    expect(entry["id"]).to eq("my-model")
    expect(entry["context_window"]).to eq(128_000)
  end

  it "returns false when the client has no llamacpp provider block" do
    path = @dir / "crush.json"
    path.write(JSON.generate({ "providers" => {} }))
    stub_const("#{described_class}::CONFIG_PATH", path)

    expect(client.sync).to be false
  end

  it "returns false when the client config is missing entirely" do
    stub_const("#{described_class}::CONFIG_PATH", @dir / "missing.json")

    expect(client.sync).to be false
  end

  # A narrow rescue took down the whole sync run once: the real failure was a
  # different errno than the one caught.
  it "returns false instead of raising when the client config is unreadable" do
    path = @dir / "crush.json"
    path.write(JSON.generate({ "providers" => { "llamacpp" => {} } }))
    path.chmod(0o000)
    stub_const("#{described_class}::CONFIG_PATH", path)

    expect(client.sync).to be false
  end
end

RSpec.describe Mimic::Client::Opencode do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  subject(:client) do
    described_class.new(Mimic::LlmConfig::Settings.new(
                          "model" => { "path" => "/models/my-model.gguf", "context_length" => 128_000 },
                          "llama" => { "port" => 8080 },
                        ))
  end

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
    stub_const("#{described_class}::CONFIG_PATH", path)

    expect { expect(client.sync).to be false }.to output(/comment/i).to_stderr
    expect(path.read).to eq(jsonc)
  end

  it "still syncs a comment-free opencode.jsonc" do
    path = @dir / "opencode.jsonc"
    path.write(JSON.generate({ "provider" => { "llamacpp" => { "models" => {} } } }))
    stub_const("#{described_class}::CONFIG_PATH", path)

    expect(client.sync).to be true
    data = JSON.parse(path.read)
    expect(data["model"]).to eq("llamacpp/my-model")
    expect(data["provider"]["llamacpp"]["models"]["my-model"]["limit"]["context"]).to eq(128_000)
  end
end

RSpec.describe Mimic::Client::Pi do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  subject(:client) do
    described_class.new(Mimic::LlmConfig::Settings.new(
                          "model" => { "path" => "/models/my-model.gguf", "context_length" => 999 },
                          "llama" => { "port" => 8080 },
                        ))
  end

  it "updates an existing model entry in place instead of duplicating" do
    path = @dir / "models.json"
    path.write(JSON.generate({
                               "providers" => { "llamacpp" => { "models" => [{ "id" => "my-model", "contextWindow" => 1 }] } },
                             }))
    stub_const("#{described_class}::CONFIG_PATH", path)
    stub_const("#{described_class}::SETTINGS_PATH", @dir / "settings-missing.json")

    expect(client.sync).to be true
    models = JSON.parse(path.read)["providers"]["llamacpp"]["models"]
    expect(models.length).to eq(1)
    expect(models.first["contextWindow"]).to eq(999)
  end
end

RSpec.describe Mimic::Client::Goose do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  subject(:client) do
    described_class.new(Mimic::LlmConfig::Settings.new(
                          "model" => { "path" => "/models/my-model.gguf", "context_length" => 999 },
                          "llama" => { "port" => 8080 },
                        ))
  end

  # Psych.safe_load needs permitted_classes to accept what a real config
  # legitimately carries.
  it "syncs when its config carries a date scalar" do
    goose = @dir / "config.yaml"
    goose.write("GOOSE_PROVIDER: openai\nlast_used: 2026-07-28\n")
    stub_const("#{described_class}::CONFIG_PATH", goose)
    stub_const("#{described_class}::PROVIDER_FILE", @dir / "custom_providers/llamacpp.json")

    expect(client.sync).to be true
    expect(goose.read).to include("GOOSE_MODEL: my-model")
  end

  # Goose has no llamacpp block to find, so an existing config file is the
  # only evidence it is installed -- without that gate the sync writes a
  # provider file into a tree goose does not own.
  it "writes nothing when goose is not installed" do
    provider_file = @dir / "custom_providers/llamacpp.json"
    stub_const("#{described_class}::CONFIG_PATH", @dir / "missing-config.yaml")
    stub_const("#{described_class}::PROVIDER_FILE", provider_file)

    expect(client.sync).to be false
    expect(provider_file).not_to exist
  end
end
