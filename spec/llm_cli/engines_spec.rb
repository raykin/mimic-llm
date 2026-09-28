require_relative "../../lib/mimic"
require_relative "../../lib/mimic/llm_cli/engines"
require "stringio"

RSpec.describe Mimic::LlmCli::Engines do
  before do
    config = Mimic::LlmConfig::Settings.new("llama" => { "engine" => "prism-v7-llama.cpp" })
    allow(Mimic::LlmConfig).to receive_messages(exists?: true, load: config)
    allow(Mimic::EngineCli::Source).to receive(:local_status).and_return(commit: "adfffbe41", dirty: false)
    allow(Mimic::EngineCli::Registry).to receive(:binaries).and_return([])
  end

  it "lists all three engines with the active engine and local details by default" do
    output = capture_stdout { described_class.start([]) }

    expect(output).to include("llama.cpp", "ik_llama.cpp", "prism-v7-llama.cpp (active)")
    expect(output.scan(/  Source:/).size).to eq(3)
    expect(output.scan(/  Branch:/).size).to eq(3)
    expect(output.scan(/  Checkout:/).size).to eq(3)
    expect(output.scan(/  Revision: adfffbe41 \(clean\)/).size).to eq(3)
    expect(output.scan(/  Binary:   missing/).size).to eq(3)
  end

  it "runs the update pass through llm engines update" do
    updater = instance_double(Mimic::EngineCli::Update, run: nil)
    allow(Mimic::EngineCli::Update).to receive(:new).and_return(updater)

    described_class.start(["update"])

    expect(updater).to have_received(:run).once
  end

  it "keeps last-good rollback under llm engines update" do
    updater = instance_double(Mimic::EngineCli::Update, rollback: nil)
    allow(Mimic::EngineCli::Update).to receive(:new).and_return(updater)

    described_class.start(["update", "--rollback", "prism-v7-llama.cpp"])

    expect(updater).to have_received(:rollback).with("prism-v7-llama.cpp")
  end

  def capture_stdout
    output = StringIO.new
    previous = $stdout
    $stdout = output
    yield
    output.string
  ensure
    $stdout = previous
  end
end
