require_relative "../../lib/mimic"
require "tmpdir"

RSpec.describe Mimic::Services::IkLlama do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  describe ".load_cache / .save_cache" do
    it "round-trips a model path -> n_cpu_moe mapping" do
      cache_path = @dir / "ik-n-cpu-moe.json"
      stub_const("Mimic::Services::IkLlama::CPU_MOE_CACHE", cache_path)
      allow(Mimic::Paths::LLM_ROOT).to receive(:mkpath)

      described_class.save_cache("/models/foo.gguf", 12)
      expect(described_class.load_cache).to eq({ "/models/foo.gguf" => 12 })
    end

    it "returns an empty hash when the cache file is missing" do
      stub_const("Mimic::Services::IkLlama::CPU_MOE_CACHE", @dir / "missing.json")
      expect(described_class.load_cache).to eq({})
    end

    it "returns an empty hash when the cache file cannot be read" do
      cache_path = @dir / "unreadable.json"
      cache_path.write("{}")
      cache_path.chmod(0o000)
      stub_const("Mimic::Services::IkLlama::CPU_MOE_CACHE", cache_path)
      expect(described_class.load_cache).to eq({})
    end
  end

  describe ".log_tail" do
    it "returns an empty string when the log cannot be read" do
      log_path = @dir / "unreadable.log"
      log_path.write("boom")
      log_path.chmod(0o000)
      stub_const("Mimic::Services::Llama::LOG_FILE", log_path)
      expect(described_class.log_tail).to eq("")
    end

    it "scrubs invalid bytes so the retry decision can still be made" do
      log_path = @dir / "server.log"
      log_path.binwrite("\xFF\xFE junk\nllm_load_print_meta: n_expert     = 0\ncudaMalloc failed\n")
      stub_const("Mimic::Services::Llama::LOG_FILE", log_path)

      tail = described_class.log_tail
      expect(tail).to be_valid_encoding
      expect(described_class.retry_blocker(tail, 0))
        .to eq("this model is dense, so it has no experts to offload")
      expect { tail.strip.lines.last(4).join }.not_to raise_error
    end
  end

  describe ".meta_int" do
    it "extracts an integer metadata value from a log tail" do
      tail = "llm_load_print_meta: n_layer         = 48\n"
      expect(described_class.meta_int(tail, "n_layer")).to eq(48)
    end

    it "returns nil when the key is absent" do
      expect(described_class.meta_int("nothing here", "n_layer")).to be_nil
    end
  end

  describe ".retry_blocker" do
    it "blocks immediately on a non-OOM failure" do
      expect(described_class.retry_blocker("segfault", 0)).to eq("startup failed for a reason other than VRAM")
    end

    it "blocks when the model is dense (no experts)" do
      tail = "cudaMalloc failed: out of memory\nllm_load_print_meta: n_expert        = 0\n"
      expect(described_class.retry_blocker(tail, 0)).to eq("this model is dense, so it has no experts to offload")
    end

    it "allows another retry while under the layer ceiling" do
      tail = "cudaMalloc failed: out of memory\nllm_load_print_meta: n_expert        = 8\n" \
             "llm_load_print_meta: n_layer         = 48\n"
      expect(described_class.retry_blocker(tail, 4)).to be_nil
    end

    it "blocks with a KV-specific message once every layer is offloaded and KV still doesn't fit" do
      tail = "cudaMalloc failed: out of memory\nllm_load_print_meta: n_expert        = 8\n" \
             "llm_load_print_meta: n_layer         = 10\n" \
             "failed to allocate buffer for kv cache\n"
      expect(described_class.retry_blocker(tail, 10)).to eq("the KV cache does not fit -- lower `model.context_length`")
    end

    it "blocks once the ceiling is hit without a KV marker" do
      tail = "cudaMalloc failed: out of memory\nllm_load_print_meta: n_expert        = 8\n" \
             "llm_load_print_meta: n_layer         = 10\n"
      expect(described_class.retry_blocker(tail, 10)).to eq("every layer is already offloaded (ceiling 10)")
    end
  end

  describe "#find_binary" do
    it "returns the configured binary when present on disk" do
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with("/opt/ik/llama-server").and_return(true)
      cfg = { "llama" => { "binary" => "/opt/ik/llama-server" } }
      expect(described_class.new(Mimic::LlmConfig::Settings.new(cfg)).find_binary).to eq("/opt/ik/llama-server")
    end

    it "falls back to a known binary path when nothing is configured" do
      cfg = { "llama" => { "binary" => "" } }
      known = described_class::KNOWN_BINARIES.first
      allow(known).to receive(:file?).and_return(true)
      expect(described_class.new(Mimic::LlmConfig::Settings.new(cfg)).find_binary).to eq(known.to_s)
    end
  end

  describe "#start" do
    it "returns an ok Result without launching when already running" do
      cfg = { "model" => { "path" => "/m.gguf" }, "llama" => {} }
      settings = Mimic::LlmConfig::Settings.new(cfg)
      llama_double = instance_double(Mimic::Services::Llama, running?: true)
      allow(Mimic::Services::Llama).to receive(:new).with(settings).and_return(llama_double)

      result = described_class.new(settings).start
      expect(result.ok?).to be true
      expect(result.message).to eq("ik_llama server already running")
    end

    it "returns an error Result when the binary cannot be found" do
      cfg = { "model" => { "path" => "/m.gguf" }, "llama" => {} }
      settings = Mimic::LlmConfig::Settings.new(cfg)
      llama_double = instance_double(Mimic::Services::Llama, running?: false)
      allow(Mimic::Services::Llama).to receive(:new).with(settings).and_return(llama_double)
      instance = described_class.new(settings)
      allow(instance).to receive(:find_binary).and_return(nil)

      result = instance.start
      expect(result.ok?).to be false
      expect(result.message).to eq("ik_llama llama-server not found -- run `mimic setup`")
    end

    it "returns an error Result when the configured model file is missing" do
      cfg = { "model" => { "path" => "/m.gguf" }, "llama" => {} }
      settings = Mimic::LlmConfig::Settings.new(cfg)
      llama_double = instance_double(Mimic::Services::Llama, running?: false)
      allow(Mimic::Services::Llama).to receive(:new).with(settings).and_return(llama_double)
      instance = described_class.new(settings)
      allow(instance).to receive(:find_binary).and_return("/bin/llama-server")
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with("/m.gguf").and_return(false)

      result = instance.start
      expect(result.ok?).to be false
      expect(result.message).to eq("GGUF model not found: /m.gguf -- run `mimic setup`")
    end

    # Python printed the retry trace on stdout; anything capturing
    # `llm start`'s stdout must still see it.
    it "prints the MoE offload and MTP notices on stdout, not stderr" do
      cfg = { "model" => { "path" => "/m.gguf" }, "llama" => {} }
      settings = Mimic::LlmConfig::Settings.new(cfg)
      llama_double = instance_double(Mimic::Services::Llama, running?: false, models_url: "http://127.0.0.1:8080/v1/models")
      allow(Mimic::Services::Llama).to receive(:new).with(settings).and_return(llama_double)
      instance = described_class.new(settings)
      allow(instance).to receive(:find_binary).and_return("/bin/llama-server")
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with("/m.gguf").and_return(true)
      allow(instance).to receive(:mtp_enabled?).and_return(true)
      allow(described_class).to receive(:load_cache).and_return({ "/m.gguf" => 8 })
      allow(instance).to receive(:launch).and_return(4242)
      allow(described_class).to receive(:save_cache)
      allow(Mimic::Probes).to receive(:wait_ready).and_return(true)

      expect { instance.start(remember: false) }
        .to output(/offloading MoE experts.*/m).to_stdout
    end

    it "closes the log handle when the spawn raises" do
      log_path = @dir / "server.log"
      stub_const("Mimic::Services::Llama::LOG_FILE", log_path)
      stub_const("Mimic::Paths::PID_DIR", @dir / "run")

      cfg = { "model" => { "path" => "/m.gguf" }, "llama" => {} }
      settings = Mimic::LlmConfig::Settings.new(cfg)
      llama_double = instance_double(Mimic::Services::Llama, running?: false)
      allow(Mimic::Services::Llama).to receive(:new).with(settings).and_return(llama_double)
      instance = described_class.new(settings)
      allow(instance).to receive(:find_binary).and_return("/bin/llama-server")
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with("/m.gguf").and_return(true)
      allow(instance).to receive(:mtp_enabled?).and_return(false)
      allow(instance).to receive(:render_preset)
      allow(described_class).to receive(:load_cache).and_return({})

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

  describe "#render_preset" do
    it "adds --n-cpu-moe only when offloading is active" do
      Dir.mktmpdir do |dir|
        launch_record = Pathname.new(dir) / "ik-llama-launch.txt"
        stub_const("Mimic::Services::IkLlama::LAUNCH_RECORD", launch_record)
        allow(Mimic::Paths::LLM_RUN_DIR).to receive(:mkpath)

        cfg = {
          "model" => { "path" => "/m.gguf", "context_length" => 1000, "temperature" => 0.6,
                        "top_p" => 0.9, "top_k" => 20, "min_p" => 0.0, "presence_penalty" => 1.0, "repeat_penalty" => 1.0 },
          "llama" => { "flash_attn" => "on", "cache_type" => "q8_0", "host" => "127.0.0.1", "port" => 8080 },
        }
        instance = described_class.new(Mimic::LlmConfig::Settings.new(cfg))
        allow(instance).to receive(:find_binary).and_return("/bin/llama-server")
        allow(instance).to receive(:chat_template_override).and_return(nil)

        instance.render_preset(0)
        without_offload = launch_record.read

        instance.render_preset(8)
        with_offload = launch_record.read

        expect(without_offload).not_to include("--n-cpu-moe")
        expect(with_offload).to include("--n-cpu-moe 8")
      end
    end
  end
end
