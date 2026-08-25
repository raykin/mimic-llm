require_relative "../../../lib/mimic"
require_relative "../../../lib/mimic/llm_cli/dev/debug"
require "tmpdir"

RSpec.describe Mimic::LlmCli::Dev::Debug do
  subject(:command) { described_class.new([], from: "llama.cpp", to: "ik_llama.cpp") }

  let(:config) do
    Mimic::LlmConfig::Settings.new(
      "model" => { "path" => "/models/prism.gguf", "context_length" => 160_000 },
      "llama" => { "engine" => "prism-v7-llama.cpp", "host" => "127.0.0.1", "port" => 8080 },
    )
  end
  let(:llama_path) { @dir / "llama.gguf" }
  let(:ik_path) { @dir / "ik.gguf" }
  let(:llama_model) { instance_double(Mimic::Model, path: llama_path) }
  let(:ik_model) { instance_double(Mimic::Model, path: ik_path) }
  let(:engine) { instance_double(Mimic::Engine::Llama, find_binary: "/bin/llama-server", render_preset: nil) }
  let(:process) { instance_double(Mimic::Engine::ServerProcess, stop: true, pids: []) }
  let(:starts) { [] }

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      llama_path.write("llama")
      ik_path.write("ik")
      example.run
    end
  end

  before do
    allow(Mimic::LlmConfig).to receive(:load).and_return(config)
    allow(Mimic::Model::Library).to receive(:new) do |settings|
      models = settings.llama.engine == "llama.cpp" ? [llama_model] : [ik_model]
      instance_double(Mimic::Model::Library, chat: models)
    end
    allow(Mimic::EngineCli::Registry).to receive(:for).and_return(engine)
    allow(engine).to receive(:start) do |remember:|
      starts << [config.llama.engine, config.model.path, config.model.context_length, remember]
      Mimic::Result.ok("ready")
    end
    allow(Mimic::Engine::ServerProcess).to receive_messages(chat: process, embed: process)
  end

  it "serves each engine with one of its compatible models" do
    command.switch

    expect(starts).to eq([
      ["llama.cpp", llama_path.to_s, described_class::CONTEXT, false],
      ["ik_llama.cpp", ik_path.to_s, described_class::CONTEXT, false],
    ])
  end

  it "does not launch when an engine has no compatible model" do
    allow(Mimic::Model::Library).to receive(:new) do |settings|
      models = settings.llama.engine == "llama.cpp" ? [llama_model] : []
      instance_double(Mimic::Model::Library, chat: models)
    end

    expect { command.switch }.to output(/no chat model compatible with ik_llama\.cpp/).to_stdout
    expect(engine).not_to have_received(:start)
  end
end
