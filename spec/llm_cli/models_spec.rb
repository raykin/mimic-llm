require_relative "../../lib/mimic"
require_relative "../../lib/mimic/llm_cli/models"
require_relative "../support/gguf_writer"
require "tmpdir"

RSpec.describe Mimic::LlmCli::Models do
  before do
    allow(Mimic::LlmConfig).to receive(:load).and_return(Mimic::LlmConfig::Settings.new({}))
    allow_any_instance_of(Mimic::Model::Library).to receive(:all).and_return([])
  end

  it "renders the board without a client for the default command" do
    expect(Mimic::LlmCli::ModelsTable).to receive(:new).with(anything, [], client: nil).and_return(instance_double(Mimic::LlmCli::ModelsTable, render: nil))

    described_class.start([])
  end

  it "hands `check` a huggingface client" do
    expect(Mimic::LlmCli::ModelsTable).to receive(:new)
      .with(anything, [], client: an_instance_of(Mimic::Util::Hf))
      .and_return(instance_double(Mimic::LlmCli::ModelsTable, render: nil))

    described_class.start(["check"])
  end

  # `llm embed` owns the embedding models; listing them on the chat board
  # offers a model `llm setup` will not accept.
  it "leaves embedding models off the board" do
    Dir.mktmpdir do |dir|
      root = Pathname.new(dir)
      GgufWriter.write(root / "chat-Q4_K_M.gguf", { "general.architecture" => "qwen3", "qwen3.block_count" => 48 })
      GgufWriter.write(root / "bge-m3-Q8_0.gguf", { "general.architecture" => "bert", "bert.attention.causal" => 0 })
      stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])
      allow_any_instance_of(Mimic::Model::Library).to receive(:all).and_call_original

      listed = nil
      allow(Mimic::LlmCli::ModelsTable).to receive(:new) do |_cfg, scan, **_opts|
        listed = scan.map { |m| m.path.basename.to_s }
        instance_double(Mimic::LlmCli::ModelsTable, render: nil)
      end
      described_class.start([])

      expect(listed).to eq(["chat-Q4_K_M.gguf"])
    end
  end
end
