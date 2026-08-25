require_relative "../../lib/mimic"
require_relative "../../lib/mimic/llm_cli"

RSpec.describe Mimic::LlmCli::Embed do
  subject(:cli) { described_class.new }

  def stub_config(embed: { "path" => "/models/bge-m3-Q8_0.gguf", "port" => 8081 })
    settings = Mimic::LlmConfig::Settings.new(
      "model" => {}, "llama" => { "host" => "127.0.0.1", "port" => 8080 }, "embed" => embed
    )
    allow(Mimic::LlmConfig).to receive_messages(exists?: true, load: settings)
    settings
  end

  it "is reachable as `llm embed`" do
    expect(Mimic::LlmCli::Root.subcommand_classes["embed"]).to eq(described_class)
  end

  describe "#start" do
    it "prints the failure and exits 1 when the server did not come up" do
      stub_config
      allow(Mimic::Engine::LlamaEmbed).to receive(:new)
        .and_return(instance_double(Mimic::Engine::LlamaEmbed, start: Mimic::Result.error("boom")))

      expect do
        expect { cli.start }.to output(/boom/).to_stdout
      end.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end
  end

  describe "#stop" do
    it "reports when nothing was running" do
      allow(Mimic::Engine::LlamaEmbed).to receive(:stop).and_return(false)
      expect { cli.stop }.to output(/was not running/).to_stdout
    end
  end

  describe "#status" do
    it "points at setup when no embedding model is configured" do
      stub_config(embed: {})
      expect { cli.status }.to output(/llm embed setup/).to_stdout
    end

    it "reports the endpoint and mode of a configured model" do
      stub_config
      allow(Mimic::Engine::LlamaEmbed).to receive(:new)
        .and_return(instance_double(Mimic::Engine::LlamaEmbed, running?: true, mode: "embeddings"))

      expect { cli.status }.to output(%r{http://127\.0\.0\.1:8081.*embeddings}m).to_stdout
    end

    it "reports the batch size the server was launched with" do
      stub_config(embed: { "path" => "/models/bge-m3-Q8_0.gguf", "port" => 8081, "batch_size" => 4096 })
      allow(Mimic::Engine::LlamaEmbed).to receive(:new)
        .and_return(instance_double(Mimic::Engine::LlamaEmbed, running?: true, mode: "embeddings"))

      expect { cli.status }.to output(/Batch:\s+4096/).to_stdout
    end
  end
end
