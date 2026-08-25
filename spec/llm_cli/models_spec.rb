require_relative "../../lib/mimic"
require_relative "../../lib/mimic/llm_cli/models"

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
end
