require_relative "../../../lib/mimic"
require_relative "../../../lib/mimic/llm_cli/wizard/embed"
require_relative "../../support/gguf_writer"
require "tmpdir"

RSpec.describe Mimic::LlmCli::Wizard::Embed do
  def settings(embed: {})
    Mimic::LlmConfig::Settings.new(
      "model" => {}, "llama" => { "host" => "127.0.0.1", "port" => 8080 }, "embed" => embed
    )
  end

  def model(path)
    Mimic::Model.new(path, path.dirname)
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  before do
    stub_const("Mimic::LlmConfig::LLM_CONFIG_PATH", @dir / "config.yaml")
    stub_const("Mimic::LlmConfig::LLM_CONFIG_DIR", @dir)
  end

  it "writes the picked model and port into the embed section" do
    path = @dir / "bge-m3-Q8_0.gguf"
    GgufWriter.write(path, { "general.architecture" => "bert", "bert.pooling_type" => 2 })
    cfg = settings
    prompt = instance_double(Mimic::Ui::Prompt)
    allow(prompt).to receive(:select) { |_, choices, **| choices.values.first }
    allow(prompt).to receive(:ask).and_return(8085, 4096)

    described_class.new(cfg, [model(path)], prompt: prompt).run

    expect(cfg.embed.path).to eq(path.to_s)
    expect(cfg.embed.port).to eq(8085)
    expect(cfg.embed.batch_size).to eq(4096)
    expect(Psych.safe_load(Mimic::LlmConfig::LLM_CONFIG_PATH.read)["embed"]["path"]).to eq(path.to_s)
  end

  it "refuses the port the chat server already owns" do
    path = @dir / "bge-m3-Q8_0.gguf"
    GgufWriter.write(path, { "general.architecture" => "bert", "bert.pooling_type" => 2 })
    prompt = instance_double(Mimic::Ui::Prompt)
    allow(prompt).to receive(:select) { |_, choices, **| choices.values.first }
    allow(prompt).to receive(:ask).and_return(8080, 8081)

    described_class.new(settings, [model(path)], prompt: prompt).run

    expect(prompt).to have_received(:ask).with(/Port/, any_args).twice
  end

  it "says so instead of prompting when no embedding model was found" do
    prompt = instance_double(Mimic::Ui::Prompt)

    expect { described_class.new(settings, [], prompt: prompt).run }
      .to output(/No embedding models found/).to_stdout
  end
end
