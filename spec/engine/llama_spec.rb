require_relative "../../lib/mimic"
require_relative "../support/gguf_writer"
require_relative "../support/guarded_template"
require "tmpdir"

RSpec.describe Mimic::Engine::Llama do
  let(:cfg) do
    {
      "llama" => { "engine" => "llama.cpp", "host" => "127.0.0.1", "port" => 8080 },
      "model" => { "path" => "/models/foo-Q4_K_M.gguf" },
    }
  end
  let(:settings) { Mimic::LlmConfig::Settings.new(cfg) }

  describe "#render_preset" do
    it "sanitizes a template that would throw and points the preset at the copy" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        stub_const("Mimic::Engine::Llama::PRESET_FILE", root / "llama-models.ini")
        stub_const("Mimic::Paths::CHAT_TEMPLATES_DIR", root / "chat-templates")
        stub_const("Mimic::Paths::GENERATED_TEMPLATES_DIR", root / "chat-templates" / "generated")

        model = root / "Guarded-Q4_K_M.gguf"
        GgufWriter.write(model, { "general.architecture" => "qwen3",
                                  "tokenizer.chat_template" => GUARDED_TEMPLATE })
        instance = described_class.new(
          Mimic::LlmConfig::Settings.new(cfg.merge("model" => { "path" => model.to_s })),
        )

        expect { instance.render_preset }.to output(/can throw/).to_stdout

        generated = root / "chat-templates" / "generated" / "Guarded.jinja"
        expect(generated.read).not_to include("raise_exception")
        expect((root / "llama-models.ini").read).to include("chat-template-file = #{generated}")
      end
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
      expect(Mimic::Util::Probes).to receive(:http_json)
        .with("http://127.0.0.1:8080/v1/models")
        .and_return({ "data" => [{ "id" => "foo", "status" => { "value" => "loaded" } }] })

      expect(described_class.new(settings).send(:model_loaded?)).to be true
    end

    it "returns true when the aliased model reports status loaded" do
      allow(Mimic::Util::Probes).to receive(:http_json)
        .and_return({ "data" => [{ "id" => "foo", "status" => { "value" => "loaded" } }] })

      expect(described_class.new(settings).send(:model_loaded?)).to be true
    end

    it "returns false when the probe comes back empty" do
      allow(Mimic::Util::Probes).to receive(:http_json).and_return(nil)

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

    # Unlike ik_llama, mainline prefers whatever is on PATH over the build
    # tree: a system llama-server is the one the user's shell would run.
    it "prefers a binary on PATH over the known build-tree paths" do
      known = Mimic::EngineCli::Registry.builds("llama.cpp").first
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with(known.to_s).and_return(true)
      allow(File).to receive(:file?).with("/usr/bin/llama-server").and_return(true)
      allow(Mimic::Util::Probes).to receive(:which).with("llama-server").and_return("/usr/bin/llama-server")
      llama_cfg = { "llama" => { "engine" => "llama.cpp", "binary" => "" } }

      expect(described_class.new(Mimic::LlmConfig::Settings.new(llama_cfg)).find_binary).to eq("/usr/bin/llama-server")
    end

    it "memoises the result instead of recomputing it on every call" do
      llama_cfg = { "llama" => { "engine" => "llama.cpp", "binary" => "" } }
      instance = described_class.new(Mimic::LlmConfig::Settings.new(llama_cfg))
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with("/usr/bin/llama-server").and_return(true)
      expect(Mimic::Util::Probes).to receive(:which).with("llama-server").once.and_return("/usr/bin/llama-server")

      2.times { instance.find_binary }
    end
  end

  describe "#start" do
    # Drives #start through its real collaborators: the binary lookup reads
    # config, the readiness probe is the HTTP boundary, and the spawn is the
    # Launcher. Nothing on the object under test is stubbed.
    def start_env(binary: "/usr/bin/llama-server", model_on_disk: true, running: false)
      allow(Mimic::EngineCli::Registry).to receive(:binaries).and_return([])
      stub_const("Mimic::Engine::Llama::PRESET_FILE", @dir / "run/llama-models.ini")
      stub_const("Mimic::Paths::LLM_RUN_DIR", @dir / "run")
      stub_const("Mimic::LlmConfig::MODEL_CTX_PATH", @dir / "model-ctx.json")
      stub_const("Mimic::LlmConfig::MODEL_COMPUTE_PATH", @dir / "model-compute.json")
      stub_const("Mimic::LlmConfig::MODEL_SAMPLING_PATH", @dir / "model-sampling.json")
      allow(Mimic::Util::Probes).to receive(:which).and_return(nil)
      allow(Mimic::Util::Probes).to receive(:http_ok).and_return(running)
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with(binary.to_s).and_return(!binary.nil?)
      allow(File).to receive(:file?).with("/models/foo-Q4_K_M.gguf").and_return(model_on_disk)
      cfg["llama"]["binary"] = binary.to_s
    end

    around do |example|
      Dir.mktmpdir { |dir| @dir = Pathname.new(dir) and example.run }
    end

    it "returns an ok Result without launching when already running" do
      start_env(running: true)

      result = described_class.new(settings).start
      expect(result.ok?).to be true
      expect(result.message).to eq("llama-server already running")
    end

    it "returns an error Result when the binary cannot be found" do
      start_env(binary: nil)

      result = described_class.new(settings).start
      expect(result.ok?).to be false
      expect(result.message).to eq("llama-server binary not found -- run `mimic setup`")
    end

    it "returns an error Result when the configured model file is missing" do
      start_env(model_on_disk: false)

      result = described_class.new(settings).start
      expect(result.ok?).to be false
      expect(result.message).to eq("GGUF model not found: /models/foo-Q4_K_M.gguf -- run `mimic setup`")
    end

    # The router survives a child that died, so a start that never reaches
    # ready has to kill the group and hand back the log tail -- otherwise the
    # caller sees a bare timeout and the process leaks.
    it "cleans up and reports the log tail when the server never becomes ready" do
      start_env
      log_path = @dir / "server.log"
      log_path.write("a previous run\n")
      process = Mimic::Engine::ServerProcess.new(pid_file: @dir / "server.pid", log_file: log_path,
                                           proc_scan_fallback: true)
      allow(Mimic::Engine::ServerProcess).to receive(:chat).and_return(process)
      launcher = instance_double(Mimic::Engine::Launcher)
      allow(launcher).to receive(:spawn) { log_path.write("ggml_cuda_init: failed\n", mode: "a") and 4242 }
      allow(Mimic::Engine::Launcher).to receive(:new).and_return(launcher)
      allow(Mimic::Util::Probes).to receive(:wait_ready).and_return(false)
      allow(process).to receive(:cleanup_failed)

      result = described_class.new(settings).start

      expect(result.ok?).to be false
      expect(result.message).to include("llama-server failed to start", "ggml_cuda_init: failed")
      expect(process).to have_received(:cleanup_failed).with(4242)
    end

    it "writes the preset before spawning, and spawns the binary it found" do
      start_env
      launcher = instance_double(Mimic::Engine::Launcher, spawn: 4242)
      allow(Mimic::Engine::Launcher).to receive(:new).and_return(launcher)
      allow(Mimic::Util::Probes).to receive(:wait_ready).and_return(true)
      allow(Mimic::Util::Probes).to receive(:wait_until).and_return(true)

      expect(described_class.new(settings).start.ok?).to be true
      expect(described_class::PRESET_FILE.read).to include("model = /models/foo-Q4_K_M.gguf")
      expect(launcher).to have_received(:spawn) do |command|
        expect(command.first).to eq("/usr/bin/llama-server")
        expect(command).to include("--models-preset", described_class::PRESET_FILE.to_s)
      end
    end

    # The compute-buffer cost is only knowable from a live instance, and the
    # instance holding the VRAM is the router's child, not the pid we spawned.
    it "records what the loaded instance cost beyond the estimate" do
      start_env
      cfg["model"]["context_length"] = 4096
      cfg["llama"]["cache_type"] = "q8_0"
      launcher = instance_double(Mimic::Engine::Launcher, spawn: 4242)
      allow(Mimic::Engine::Launcher).to receive(:new).and_return(launcher)
      allow(Mimic::Util::Probes).to receive(:wait_ready).and_return(true)
      allow(Mimic::Util::Probes).to receive(:wait_until).and_return(true)
      allow(Mimic::Util::Probes).to receive(:descendants).with(4242).and_return([4243])
      measured = instance_double(Mimic::Model::Footprint)
      allow(measured).to receive(:measured_overhead_mib).with(pids: [4242, 4243]).and_return(2431)
      expect_any_instance_of(Mimic::Model).to receive(:footprint)
        .with(4096, "q8_0", compute_mib: 0).and_return(measured)

      expect(described_class.new(settings).start.ok?).to be true
      expect(Mimic::Model.new("/models/foo-Q4_K_M.gguf").memory.compute_mib(4096, "q8_0")).to eq(2431)
    end

    it "records nothing when the instance's VRAM cannot be measured" do
      start_env
      launcher = instance_double(Mimic::Engine::Launcher, spawn: 4242)
      allow(Mimic::Engine::Launcher).to receive(:new).and_return(launcher)
      allow(Mimic::Util::Probes).to receive(:wait_ready).and_return(true)
      allow(Mimic::Util::Probes).to receive(:wait_until).and_return(true)
      allow(Mimic::Util::Probes).to receive(:descendants).and_return([])
      allow_any_instance_of(Mimic::Model).to receive(:footprint).and_return(
        instance_double(Mimic::Model::Footprint, measured_overhead_mib: nil),
      )

      expect(described_class.new(settings).start.ok?).to be true
      expect(Mimic::LlmConfig::MODEL_COMPUTE_PATH).not_to exist
    end
  end

end
