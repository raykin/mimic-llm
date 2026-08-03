require_relative "../../lib/mimic"
require "tmpdir"

RSpec.describe Mimic::Services::Llama do
  let(:cfg) do
    {
      "llama" => { "engine" => "llama.cpp", "host" => "127.0.0.1", "port" => 8080 },
      "model" => { "path" => "/models/foo-Q4_K_M.gguf" },
    }
  end
  let(:settings) { Mimic::LlmConfig::Settings.new(cfg) }

  describe ".log_tail" do
    it "reads from an offset and scrubs invalid bytes" do
      Dir.mktmpdir do |dir|
        log_path = Pathname.new(dir) / "server.log"
        log_path.binwrite("prelude\n\xFF\xFE junk\nline one\nline two\n")
        stub_const("Mimic::Services::Llama::LOG_FILE", log_path)

        tail = described_class.log_tail("prelude\n".bytesize)
        expect(tail).to be_valid_encoding
        expect(tail).to include("line two")
        expect(tail).not_to include("prelude")
      end
    end

    it "returns an empty string when the log cannot be read" do
      stub_const("Mimic::Services::Llama::LOG_FILE", Pathname.new("/nope/missing.log"))
      expect(described_class.log_tail).to eq("")
    end
  end

  describe ".last_lines" do
    it "joins the last n lines only" do
      text = "a\nb\nc\nd\ne\n"
      expect(described_class.last_lines(text, 2)).to eq("d\ne")
    end
  end

  describe "#models_url" do
    it "targets the OpenAI-compatible /v1/models path" do
      expect(described_class.new(settings).models_url).to eq("http://127.0.0.1:8080/v1/models")
    end
  end

  describe ".supports_mtp?" do
    # Python caught OSError, so an unreadable or directory-shaped model path
    # falls back to "no MTP" instead of raising out of render_preset.
    it "returns false for a directory instead of raising" do
      expect(described_class.supports_mtp?(Dir.tmpdir)).to be false
    end

    it "returns false for an unreadable file instead of raising" do
      Dir.mktmpdir do |dir|
        path = Pathname.new(dir) / "model.gguf"
        path.write("nextn_predict_layers")
        path.chmod(0o000)
        expect(described_class.supports_mtp?(path.to_s)).to be false
      end
    end

    it "returns false for a missing path" do
      expect(described_class.supports_mtp?("/nope/missing.gguf")).to be false
    end
  end

  describe "#model_loaded? (private)" do
    # Regression: model_loaded? polls a different path ("/models") than
    # every other call site ("/v1/models" via models_url), so it 404s
    # against a live router and the load-wait loop always times out even
    # after the model has actually finished loading. Its only reachable
    # path is the load-wait loop inside #start, which is expensive to
    # drive end-to-end in a spec -- kept as a direct private-method test
    # per ruby-style.md's regression-pinning exception.
    it "polls the same /v1/models endpoint as models_url, not a bare /models path" do
      expect(Mimic::Probes).to receive(:http_json)
        .with("http://127.0.0.1:8080/v1/models")
        .and_return({ "data" => [{ "id" => "foo", "status" => { "value" => "loaded" } }] })

      expect(described_class.new(settings).send(:model_loaded?)).to be true
    end

    it "returns true when the aliased model reports status loaded" do
      allow(Mimic::Probes).to receive(:http_json)
        .and_return({ "data" => [{ "id" => "foo", "status" => { "value" => "loaded" } }] })

      expect(described_class.new(settings).send(:model_loaded?)).to be true
    end

    it "returns false when the probe comes back empty" do
      allow(Mimic::Probes).to receive(:http_json).and_return(nil)

      expect(described_class.new(settings).send(:model_loaded?)).to be false
    end
  end

  describe "#find_binary" do
    it "returns the configured binary when it exists on disk" do
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with("/usr/bin/llama-server").and_return(true)
      llama_cfg = { "llama" => { "engine" => "llama.cpp", "binary" => "/usr/bin/llama-server" } }
      expect(described_class.new(Mimic::LlmConfig::Settings.new(llama_cfg)).find_binary).to eq("/usr/bin/llama-server")
    end

    it "memoises the result instead of recomputing it on every call" do
      llama_cfg = { "llama" => { "engine" => "llama.cpp", "binary" => "" } }
      instance = described_class.new(Mimic::LlmConfig::Settings.new(llama_cfg))
      expect(Mimic::Probes).to receive(:which).with("llama-server").once.and_return("/usr/bin/llama-server")

      2.times { instance.find_binary }
    end
  end

  describe "#start" do
    it "returns an ok Result without launching when already running" do
      instance = described_class.new(settings)
      allow(instance).to receive(:running?).and_return(true)

      result = instance.start
      expect(result.ok?).to be true
      expect(result.message).to eq("llama-server already running")
    end

    it "returns an error Result when the binary cannot be found" do
      instance = described_class.new(settings)
      allow(instance).to receive(:running?).and_return(false)
      allow(instance).to receive(:find_binary).and_return(nil)

      result = instance.start
      expect(result.ok?).to be false
      expect(result.message).to eq("llama-server binary not found -- run `mimic setup`")
    end

    it "returns an error Result when the configured model file is missing" do
      instance = described_class.new(settings)
      allow(instance).to receive(:running?).and_return(false)
      allow(instance).to receive(:find_binary).and_return("/usr/bin/llama-server")
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with("/models/foo-Q4_K_M.gguf").and_return(false)

      result = instance.start
      expect(result.ok?).to be false
      expect(result.message).to eq("GGUF model not found: /models/foo-Q4_K_M.gguf -- run `mimic setup`")
    end

    it "closes the log handle when the spawn raises" do
      Dir.mktmpdir do |dir|
        log_path = Pathname.new(dir) / "server.log"
        stub_const("Mimic::Services::Llama::LOG_FILE", log_path)
        stub_const("Mimic::Paths::PID_DIR", Pathname.new(dir) / "run")

        instance = described_class.new(settings)
        allow(instance).to receive(:running?).and_return(false)
        allow(instance).to receive(:find_binary).and_return("/usr/bin/llama-server")
        allow(instance).to receive(:render_preset)
        allow(File).to receive(:file?).and_call_original
        allow(File).to receive(:file?).with("/models/foo-Q4_K_M.gguf").and_return(true)

        opened = nil
        allow(File).to receive(:open).and_call_original
        allow(File).to receive(:open).with(log_path, "ab") do
          opened = File.new(log_path, "ab")
        end
        allow(Process).to receive(:spawn).and_raise(Errno::ENOENT)

        expect { instance.start }.to raise_error(Errno::ENOENT)
        expect(opened).not_to be_nil
        expect(opened).to be_closed
      end
    end
  end

  describe ".cleanup_failed" do
    # Regression: both engines are spawned with pgroup: true because router
    # mode's real model process is a grandchild the router respawns -- but
    # cleanup only signals the direct pid, leaving the grandchild (and its
    # VRAM) orphaned.
    it "signals the process group, not only the direct pid" do
      allow(described_class::PID_FILE).to receive(:exist?).and_return(false)
      allow(Mimic::Probes).to receive(:child_alive?).with(4242).and_return(true)
      allow(Process).to receive(:waitpid)

      expect(Process).to receive(:kill).with("TERM", -4242)

      described_class.cleanup_failed(4242)
    end
  end
end
