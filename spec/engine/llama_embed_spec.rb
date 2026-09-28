require_relative "../../lib/mimic"
require_relative "../../lib/mimic/engine/llama_embed"
require_relative "../support/gguf_writer"
require "tmpdir"

RSpec.describe Mimic::Engine::LlamaEmbed do
  def settings(embed: {}, llama: {})
    Mimic::LlmConfig::Settings.new(
      "model" => { "path" => "/models/chat-Q4_K_M.gguf" },
      "llama" => { "host" => "0.0.0.0", "port" => 8080, "binary" => { "llama.cpp" => "/bin/llama-server" } }.merge(llama),
      "embed" => { "path" => "/models/bge-m3-Q8_0.gguf" }.merge(embed),
    )
  end

  # Selected by role, not by config: Registry.for dispatches on
  # llama.engine and Registry.names drives the setup wizard's engine picker,
  # so an entry there would offer the encoder as a chat engine.
  it "is not reachable through the engine registry" do
    picked = Mimic::EngineCli::Registry.names.map do |name|
      Mimic::EngineCli::Registry.for(settings(llama: { "engine" => name })).class
    end
    expect(picked).not_to include(described_class)
  end

  describe "#process" do
    # A /proc scan for "llama-server" would match the chat server, which is
    # the same binary on a different port -- so the embedding server takes
    # the process object that refuses that fallback.
    it "is the embedding server's process, not the chat server's" do
      instance = described_class.new(settings)

      expect(instance.process.pid_file).to eq(Mimic::Engine::ServerProcess.embed.pid_file)
      expect(instance.process.log_file).to eq(Mimic::Engine::ServerProcess.embed.log_file)
      expect(instance.process.proc_scan_fallback?).to be false
    end
  end

  describe ".mode_for" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = Pathname.new(dir)
        example.run
      end
    end

    it "is rerank when the header asks for rank pooling" do
      path = @dir / "model.gguf"
      GgufWriter.write(path, { "general.architecture" => "bert", "bert.pooling_type" => 4 })
      expect(described_class.mode_for(path)).to eq("rerank")
    end

    # bge-reranker ships no pooling_type at all, so the filename is the only
    # thing left that says it ranks pairs instead of embedding one text.
    it "is rerank when the filename says so and the header is silent" do
      path = @dir / "bge-reranker-v2-m3-Q8_0.gguf"
      GgufWriter.write(path, { "general.architecture" => "bert", "bert.attention.causal" => 0 })
      expect(described_class.mode_for(path)).to eq("rerank")
    end

    it "is embeddings otherwise" do
      path = @dir / "bge-m3-Q8_0.gguf"
      GgufWriter.write(path, { "general.architecture" => "bert", "bert.pooling_type" => 2 })
      expect(described_class.mode_for(path)).to eq("embeddings")
    end
  end

  describe "#start" do
    def launched_argv(embed: {})
      instance = described_class.new(settings(embed: embed))
      allow(instance).to receive_messages(running?: false, find_binary: "/bin/llama-server")
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with("/models/bge-m3-Q8_0.gguf").and_return(true)
      argv = nil
      launcher = instance_double(Mimic::Engine::Launcher)
      allow(launcher).to receive(:spawn) { |command| (argv = command) && 4242 }
      allow(Mimic::Engine::Launcher).to receive(:new).and_return(launcher)
      allow(instance.process).to receive(:log_size).and_return(0)
      allow(Mimic::Util::Probes).to receive(:wait_ready).and_return(true)

      expect(instance.start).to be_ok
      argv
    end

    it "launches the embedding model on its own port with the embeddings endpoint" do
      allow(described_class).to receive(:mode_for).and_return("embeddings")

      expect(launched_argv).to eq(
        ["/bin/llama-server", "-m", "/models/bge-m3-Q8_0.gguf", "-a", "bge-m3",
         "--host", "0.0.0.0", "--port", "8081", "--ctx-size", "0",
         "-b", "8192", "-ub", "8192", "-ngl", "999", "--embeddings"]
      )
    end

    it "passes a configured batch size through to both batch flags" do
      allow(described_class).to receive(:mode_for).and_return("embeddings")

      expect(launched_argv(embed: { "batch_size" => 4096 })).to include("-b", "4096", "-ub", "4096")
    end

    it "asks for the rerank endpoint when the mode resolves to rerank" do
      allow(described_class).to receive(:mode_for).and_return("rerank")

      expect(launched_argv).to include("--rerank")
    end

    it "honours an explicit mode over what the GGUF says" do
      allow(described_class).to receive(:mode_for).and_return("rerank")

      expect(launched_argv(embed: { "mode" => "embeddings" })).to include("--embeddings")
    end

    it "passes a configured context length through" do
      allow(described_class).to receive(:mode_for).and_return("embeddings")

      expect(launched_argv(embed: { "context_length" => 8192 })).to include("--ctx-size", "8192")
    end

    it "refuses to start on the chat server's port" do
      instance = described_class.new(settings(embed: { "port" => 8080 }))

      result = instance.start
      expect(result).not_to be_ok
      expect(result.message).to include("same port")
    end

    it "reports an unconfigured embedding model instead of launching" do
      instance = described_class.new(settings(embed: { "path" => "" }))

      result = instance.start
      expect(result).not_to be_ok
      expect(result.message).to include("llm embed setup")
    end
  end

  describe "#running?" do
    it "probes its own port, not the chat server's" do
      allow(Mimic::Util::Probes).to receive(:http_ok).with("http://127.0.0.1:8081/health").and_return(true)
      expect(described_class.new(settings)).to be_running
    end
  end
end
