require_relative "../../lib/mimic"
require_relative "../support/gguf_writer"
require_relative "../support/guarded_template"
require "tmpdir"

RSpec.describe Mimic::Engine::IkLlama do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  # #start remembers the context it booted at; without this the suite writes
  # the user's real ~/.llm/model-ctx.json.
  before do
    stub_const("Mimic::LlmConfig::LLM_CONFIG_DIR", @dir)
    stub_const("Mimic::LlmConfig::MODEL_CTX_PATH", @dir / "model-ctx.json")
    stub_const("Mimic::LlmConfig::MODEL_MMPROJ_PATH", @dir / "model-mmproj.json")
    stub_const("Mimic::LlmConfig::MODEL_COMPUTE_PATH", @dir / "model-compute.json")
    stub_const("Mimic::LlmConfig::MODEL_SAMPLING_PATH", @dir / "model-sampling.json")
    stub_const("Mimic::Model::Memory::N_CPU_MOE_PATH", @dir / "ik-n-cpu-moe.json")
    allow(Mimic::Util::Probes).to receive(:port_free?).and_return(true)
  end

  def server_process(log_path)
    process = Mimic::Engine::ServerProcess.new(pid_file: @dir / "server.pid", log_file: log_path,
                                               proc_scan_fallback: true)
    allow(Mimic::Engine::ServerProcess).to receive(:chat).and_return(process)
    process
  end

  describe "#find_binary" do
    it "returns the configured binary when present on disk" do
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with("/opt/ik/llama-server").and_return(true)
      cfg = { "llama" => { "binary" => "/opt/ik/llama-server" } }
      expect(described_class.new(Mimic::LlmConfig::Settings.new(cfg)).find_binary).to eq("/opt/ik/llama-server")
    end

    it "falls back to its own build before anything on PATH" do
      cfg = { "llama" => { "engine" => "ik_llama.cpp", "binary" => "" } }
      known = Mimic::EngineCli::Registry.builds("ik_llama.cpp").first.to_s
      allow(File).to receive(:file?).and_return(false)
      allow(File).to receive(:file?).with(known).and_return(true)
      allow(Mimic::Util::Probes).to receive(:which).with("llama-server").and_return("/usr/bin/llama-server")

      expect(described_class.new(Mimic::LlmConfig::Settings.new(cfg)).find_binary).to eq(known)
    end
  end

  # ik's runtime config is the launch record rather than a preset INI, but it
  # carries the same risk: one file, rewritten per model, holding the argv the
  # previous model was launched with.
  describe "#render_preset" do
    it "replaces a launch record left by a previous model instead of adding to it" do
      allow(Mimic::EngineCli::Registry).to receive(:binaries).and_return([])
      stub_const("Mimic::Paths::LLM_RUN_DIR", @dir / "run")
      stub_const("Mimic::Engine::IkLlama::LAUNCH_RECORD", @dir / "run/ik-llama-launch.txt")
      allow(Mimic::Util::Probes).to receive(:which).and_return(nil)
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with("/bin/llama-server").and_return(true)
      settings = Mimic::LlmConfig::Settings.new(
        { "model" => { "path" => "/m.gguf" }, "llama" => { "binary" => "/bin/llama-server" } },
      )
      record = described_class::LAUNCH_RECORD
      record.dirname.mkpath
      record.write("/bin/llama-server -m /old.gguf --temp 0.42\n")

      described_class.new(settings).render_preset

      expect(record.read).to include("-m /m.gguf")
      expect(record.read).not_to include("/old.gguf", "--temp 0.42")
    end
  end

  # A nil reaches ARG_FLAGS as "no value", and the flag has to go with it.
  # `-c ""` used to reach llama-server and fail loudly on parse; dropping the
  # flag instead lets the server pick its own default, which is quieter and
  # therefore worth pinning rather than assuming.
  describe "#render_preset with a nil value" do
    it "drops the flag rather than emitting it with an empty value" do
      allow(Mimic::EngineCli::Registry).to receive(:binaries).and_return([])
      stub_const("Mimic::Paths::LLM_RUN_DIR", @dir / "run")
      stub_const("Mimic::Engine::IkLlama::LAUNCH_RECORD", @dir / "run/ik-llama-launch.txt")
      allow(Mimic::Util::Probes).to receive(:which).and_return(nil)
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with("/bin/llama-server").and_return(true)
      settings = Mimic::LlmConfig::Settings.new(
        { "model" => { "path" => "/m.gguf", "context_length" => nil },
          "llama" => { "binary" => "/bin/llama-server" } },
      )

      described_class.new(settings).render_preset

      argv = described_class::LAUNCH_RECORD.read
      expect(argv).not_to match(/-c(\s|$)/)
      expect(argv).to include("-m /m.gguf")
    end
  end

  describe "#render_preset and the CUDA graph cache" do
    it "disables CUDA graphs" do
      allow(Mimic::EngineCli::Registry).to receive(:binaries).and_return([])
      stub_const("Mimic::Paths::LLM_RUN_DIR", @dir / "run")
      stub_const("Mimic::Engine::IkLlama::LAUNCH_RECORD", @dir / "run/ik-llama-launch.txt")
      allow(Mimic::Util::Probes).to receive(:which).and_return(nil)
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with("/bin/llama-server").and_return(true)
      settings = Mimic::LlmConfig::Settings.new(
        { "model" => { "path" => "/m.gguf" }, "llama" => { "binary" => "/bin/llama-server" } },
      )

      described_class.new(settings).render_preset

      expect(described_class::LAUNCH_RECORD.read).to include("-cuda graphs=0")
    end

    it "compacts the sliding-window cache" do
      allow(Mimic::EngineCli::Registry).to receive(:binaries).and_return([])
      stub_const("Mimic::Paths::LLM_RUN_DIR", @dir / "run")
      stub_const("Mimic::Engine::IkLlama::LAUNCH_RECORD", @dir / "run/ik-llama-launch.txt")
      allow(Mimic::Util::Probes).to receive(:which).and_return(nil)
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with("/bin/llama-server").and_return(true)
      settings = Mimic::LlmConfig::Settings.new(
        { "model" => { "path" => "/m.gguf" }, "llama" => { "binary" => "/bin/llama-server" } },
      )

      described_class.new(settings).render_preset

      expect(described_class::LAUNCH_RECORD.read.split).to include("--swa-compress")
    end
  end

  describe "#render_preset and the thinking level" do
    def launch_record(model)
      allow(Mimic::EngineCli::Registry).to receive(:binaries).and_return([])
      stub_const("Mimic::Paths::LLM_RUN_DIR", @dir / "run")
      stub_const("Mimic::Engine::IkLlama::LAUNCH_RECORD", @dir / "run/ik-llama-launch.txt")
      stub_const("Mimic::LlmConfig::MODEL_EFFORT_PATH", @dir / "model-effort.json")
      allow(Mimic::Util::Probes).to receive(:which).and_return(nil)
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with("/bin/llama-server").and_return(true)
      settings = Mimic::LlmConfig::Settings.new({ "model" => model, "llama" => { "binary" => "/bin/llama-server" } })
      yield settings if block_given?

      described_class.new(settings).render_preset
      described_class::LAUNCH_RECORD.read
    end

    it "hands the picked level to the template through its kwargs" do
      record = launch_record({ "path" => "/m.gguf" }) { |settings| settings.model.reasoning_effort = "low" }

      expect(record).to include(%(--chat-template-kwargs {"reasoning_effort":"low"}))
    end

    it "sends no kwargs when no level was picked" do
      expect(launch_record({ "path" => "/m.gguf" })).not_to include("--chat-template-kwargs")
    end

    it "sends no kwargs when thinking is off" do
      record = launch_record({ "path" => "/m.gguf", "reasoning" => "off" }) do |settings|
        settings.model.reasoning_effort = "low"
      end

      expect(record).not_to include("--chat-template-kwargs")
    end
  end

  describe "#start" do
    def settings_for(mtp: "off", binary: "/bin/llama-server", model: "/m.gguf", model_on_disk: true)
      allow(Mimic::EngineCli::Registry).to receive(:binaries).and_return([])
      stub_const("Mimic::Paths::LLM_RUN_DIR", @dir / "run")
      stub_const("Mimic::Engine::IkLlama::LAUNCH_RECORD", @dir / "run/ik-llama-launch.txt")
      allow(Mimic::Util::Probes).to receive(:which).and_return(nil)
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with(binary.to_s).and_return(!binary.nil?)
      allow(File).to receive(:file?).with(model).and_return(model_on_disk)
      Mimic::LlmConfig::Settings.new(
        { "model" => { "path" => model, "mtp" => mtp },
          "llama" => { "binary" => binary.to_s, "host" => "127.0.0.1", "port" => 8080 } },
      )
    end

    def stub_llama(_settings, running:, spawns: nil)
      allow(Mimic::Util::Probes).to receive(:http_ok).and_return(running)
      # The preflight budget asks the running server what it holds; unstubbed
      # that reads the real pid file and shells out to the real nvidia-smi.
      allow_any_instance_of(Mimic::Engine::ServerProcess).to receive(:gpu_mib).and_return(0)
      return unless spawns

      allow(Mimic::Engine::Launcher).to receive(:new)
        .and_return(instance_double(Mimic::Engine::Launcher, spawn: spawns))
    end

    # An over-committed context starts fine and dies later once the KV fills,
    # so the OOM retry loop never runs and the cached n_cpu_moe stays pinned
    # at whatever last succeeded. The preflight is what catches it.
    it "raises the cached n_cpu_moe when the preflight says the context will not fit" do
      settings = settings_for
      stub_llama(settings, running: false, spawns: 4242)
      Mimic::Model.new("/m.gguf").memory.remember_n_cpu_moe(0)
      allow_any_instance_of(Mimic::Model).to receive(:footprint).and_return(
        instance_double(Mimic::Model::Footprint, measurable?: true, fits?: false, layers_to_offload: 6,
                        measured_overhead_mib: nil),
      )
      allow(Mimic::Util::Probes).to receive(:wait_ready).and_return(true)
      allow_any_instance_of(Mimic::Model::Header).to receive(:block_count).and_return(40)

      expect { described_class.new(settings).start }.to output(/offloading MoE experts of first 6 layers/).to_stdout

      expect(described_class::LAUNCH_RECORD.read).to include("--n-cpu-moe 6")
      expect(Mimic::Model.new("/m.gguf").memory.n_cpu_moe).to eq(6)
    end

    it "records what the loaded instance cost beyond the estimate" do
      settings = settings_for
      stub_llama(settings, running: false, spawns: 4242)
      allow(Mimic::Util::Probes).to receive(:wait_ready).and_return(true)
      allow(Mimic::Util::Probes).to receive(:descendants).and_return([])
      settings.model.context_length = 65_536
      settings.llama.cache_type = "q8_0"
      measured = instance_double(Mimic::Model::Footprint, measurable?: true, fits?: true)
      allow(measured).to receive(:measured_overhead_mib).with(pids: [4242]).and_return(1712)
      allow_any_instance_of(Mimic::Model).to receive(:footprint).and_return(measured)

      described_class.new(settings).start

      expect(Mimic::Model.new("/m.gguf").memory.compute_mib(65_536, "q8_0")).to eq(1712)
    end

    it "leaves the cached n_cpu_moe alone when the preflight fits" do
      settings = settings_for
      stub_llama(settings, running: false, spawns: 4242)
      Mimic::Model.new("/m.gguf").memory.remember_n_cpu_moe(3)
      allow_any_instance_of(Mimic::Model).to receive(:footprint).and_return(
        instance_double(Mimic::Model::Footprint, measurable?: true, fits?: true, measured_overhead_mib: nil),
      )
      allow(Mimic::Util::Probes).to receive(:wait_ready).and_return(true)

      described_class.new(settings).start

      expect(described_class::LAUNCH_RECORD.read).to include("--n-cpu-moe 3")
    end

    it "returns an ok Result without launching when already running" do
      settings = settings_for
      stub_llama(settings, running: true)

      result = described_class.new(settings).start
      expect(result.ok?).to be true
      expect(result.message).to eq("ik_llama server already running")
    end

    it "returns an error Result when the binary cannot be found" do
      settings = settings_for(binary: nil)
      stub_llama(settings, running: false)

      result = described_class.new(settings).start
      expect(result.ok?).to be false
      expect(result.message).to eq("ik_llama llama-server not found -- run `mimic setup`")
    end

    it "returns an error Result when the configured model file is missing" do
      settings = settings_for(model_on_disk: false)
      stub_llama(settings, running: false)

      result = described_class.new(settings).start
      expect(result.ok?).to be false
      expect(result.message).to eq("GGUF model not found: /m.gguf -- run `mimic setup`")
    end

    # Python printed the retry trace on stdout; anything capturing
    # `llm start`'s stdout must still see it.
    it "prints the MoE offload notice on stdout, not stderr" do
      settings = settings_for(mtp: "on")
      stub_llama(settings, running: false, spawns: 4242)
      Mimic::Model.new("/m.gguf").memory.remember_n_cpu_moe(8)
      allow(Mimic::Util::Probes).to receive(:wait_ready).and_return(true)

      expect { described_class.new(settings).start(remember: false) }
        .to output(/offloading MoE experts of first 8 layers/).to_stdout
    end

    it "drafts with the MTP head when mtp is on" do
      settings = settings_for(mtp: "on")
      stub_llama(settings, running: false, spawns: 4242)
      allow(Mimic::Util::Probes).to receive(:wait_ready).and_return(true)

      described_class.new(settings).start(remember: false)

      expect(described_class::LAUNCH_RECORD.read).to include("--spec-type mtp:n_max=4")
    end

    it "omits the spec stage when mtp is off" do
      settings = settings_for(mtp: "off")
      stub_llama(settings, running: false, spawns: 4242)
      allow(Mimic::Util::Probes).to receive(:wait_ready).and_return(true)

      described_class.new(settings).start(remember: false)

      expect(described_class::LAUNCH_RECORD.read).not_to include("--spec-type")
    end

    # ik creates the MTP draft context after the weights and KV are resident,
    # so the stage can OOM a load that fits without it. The tail carries the
    # same "out of memory" retry_blocker keys on, and n_expert = 0 would have
    # it answer "dense, no experts to offload" -- a verdict about the wrong
    # subsystem. Dropping the draft stage is the repair.
    it "restarts without speculative decoding when the MTP context cannot fit" do
      settings = settings_for(mtp: "on")
      stub_llama(settings, running: false, spawns: 77)
      log = @dir / "mtp.log"
      log.write("ggml_backend_cuda_buffer_type_alloc_buffer: cudaMalloc failed: out of memory\n" \
                "common_speculative_init: failed to create MTP context\n" \
                "llm_load_print_meta: n_expert         = 0\n")
      allow(server_process(log)).to receive(:cleanup_failed)
      allow(Mimic::Util::Probes).to receive(:wait_ready).and_return(false, true)

      result = nil
      expect { result = described_class.new(settings).start(remember: false) }
        .to output(/no VRAM left for the MTP draft context/).to_stdout

      expect(result).to be_ok
      expect(described_class::LAUNCH_RECORD.read).not_to include("--spec-type")
    end

    # The auto-tune loop: an OOM that retry_blocker clears means relaunch with
    # CPU_MOE_STEP more layers offloaded, and only the value that finally
    # booted is what gets cached.
    it "retries with more layers offloaded after a recoverable OOM" do
      settings = settings_for
      stub_llama(settings, running: false, spawns: 99)
      log = @dir / "retry.log"
      log.write("cudaMalloc failed: out of memory\nllm_load_print_meta: n_expert        = 8\n" \
                "llm_load_print_meta: n_layer         = 48\n")
      allow(server_process(log)).to receive(:cleanup_failed)
      allow(Mimic::Util::Probes).to receive(:wait_ready).and_return(false, true)

      result = nil
      expect { result = described_class.new(settings).start(remember: false) }
        .to output(/offloading MoE experts of first #{described_class::CPU_MOE_STEP} layers/).to_stdout
      expect(result.ok?).to be true
      expect(Mimic::Model.new("/m.gguf").memory.n_cpu_moe).to eq(described_class::CPU_MOE_STEP)
    end

    describe "when a failed launch cannot be rescued by offloading more" do
      def start_failing_with(log_bytes, cached_n_cpu_moe: nil)
        settings = settings_for
        stub_llama(settings, running: false, spawns: 99)
        Mimic::Model.new("/m.gguf").memory.remember_n_cpu_moe(cached_n_cpu_moe) if cached_n_cpu_moe
        log = @dir / "failed.log"
        log.binwrite(log_bytes)
        allow(server_process(log)).to receive(:cleanup_failed)
        allow(Mimic::Util::Probes).to receive(:wait_ready).and_return(false)

        result = described_class.new(settings).start(remember: false)
        expect(result.ok?).to be false
        result.message
      end

      # The log may carry invalid bytes, so the verdict is read from a
      # scrubbed tail rather than raising on one.
      it "reports a dense model, even from a log with invalid bytes" do
        message = start_failing_with("\xFF\xFE junk\ncudaMalloc failed: out of memory\n" \
                                     "llm_load_print_meta: n_expert        = 0\n")
        expect(message).to include("this model is dense, so it has no experts to offload")
      end

      it "names the port conflict rather than blaming VRAM when the bind failed" do
        message = start_failing_with("couldn't bind to server socket: hostname=127.0.0.1 port=8080\n")
        expect(message).to include("port 8080 is still held by another process")
      end

      it "blocks immediately on a non-OOM failure" do
        expect(start_failing_with("segfault\n")).to include("startup failed for a reason other than VRAM")
      end

      it "names the KV cache once every layer is offloaded and it still does not fit" do
        message = start_failing_with("cudaMalloc failed: out of memory\nllm_load_print_meta: n_expert        = 8\n" \
                                     "llm_load_print_meta: n_layer         = 10\n" \
                                     "failed to allocate buffer for kv cache\n", cached_n_cpu_moe: 10)
        expect(message).to include("the KV cache does not fit -- lower `model.context_length`")
      end

      it "stops once every layer is offloaded without a KV marker" do
        message = start_failing_with("cudaMalloc failed: out of memory\nllm_load_print_meta: n_expert        = 8\n" \
                                     "llm_load_print_meta: n_layer         = 10\n", cached_n_cpu_moe: 10)
        expect(message).to include("every layer is already offloaded (ceiling 10)")
      end
    end
  end

  describe "#render_preset" do
    it "adds --n-cpu-moe only when offloading is active" do
      Dir.mktmpdir do |dir|
        launch_record = Pathname.new(dir) / "ik-llama-launch.txt"
        stub_const("Mimic::Engine::IkLlama::LAUNCH_RECORD", launch_record)
        allow(Mimic::Paths::LLM_RUN_DIR).to receive(:mkpath)

        stub_const("Mimic::Paths::CHAT_TEMPLATES_DIR", Pathname.new(dir) / "no-templates")
        allow(File).to receive(:file?).and_call_original
        allow(File).to receive(:file?).with("/bin/llama-server").and_return(true)

        cfg = {
          "model" => { "path" => "/m.gguf", "context_length" => 1000, "temperature" => 0.6,
                        "top_p" => 0.9, "top_k" => 20, "min_p" => 0.0, "presence_penalty" => 1.0, "repeat_penalty" => 1.0 },
          "llama" => { "binary" => "/bin/llama-server", "flash_attn" => "on", "cache_type" => "q8_0",
                        "host" => "127.0.0.1", "port" => 8080 },
        }
        instance = described_class.new(Mimic::LlmConfig::Settings.new(cfg))

        instance.render_preset(0)
        without_offload = launch_record.read

        instance.render_preset(8)
        with_offload = launch_record.read

        expect(without_offload).not_to include("--n-cpu-moe")
        expect(with_offload).to include("--n-cpu-moe 8")
      end
    end

    it "spells every flag from ARG_FLAGS, the table the read-back also uses" do
      Dir.mktmpdir do |dir|
        launch_record = Pathname.new(dir) / "ik-llama-launch.txt"
        stub_const("Mimic::Engine::IkLlama::LAUNCH_RECORD", launch_record)
        allow(Mimic::Paths::LLM_RUN_DIR).to receive(:mkpath)
        stub_const("Mimic::Paths::CHAT_TEMPLATES_DIR", Pathname.new(dir) / "no-templates")
        allow(File).to receive(:file?).and_call_original
        allow(File).to receive(:file?).with("/bin/llama-server").and_return(true)
        stub_const("Mimic::Engine::IkLlama::ARG_FLAGS",
                   described_class::ARG_FLAGS.merge(ctx: "-cX", cache_type: "-ctkX"))

        cfg = {
          "model" => { "path" => "/m.gguf", "context_length" => 1000, "temperature" => 0.6,
                       "top_p" => 0.9, "top_k" => 20, "min_p" => 0.0, "presence_penalty" => 1.0,
                       "repeat_penalty" => 1.0 },
          "llama" => { "binary" => "/bin/llama-server", "flash_attn" => "on", "cache_type" => "q8_0",
                       "host" => "127.0.0.1", "port" => 8080 },
        }
        described_class.new(Mimic::LlmConfig::Settings.new(cfg)).render_preset(0)

        expect(launch_record.read).to include("-cX 1000", "-ctkX q8_0", "--reasoning auto")
      end
    end

    it "hands the server a sanitized copy of a template that would throw" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        launch_record = root / "ik-llama-launch.txt"
        stub_const("Mimic::Engine::IkLlama::LAUNCH_RECORD", launch_record)
        allow(Mimic::Paths::LLM_RUN_DIR).to receive(:mkpath)
        stub_const("Mimic::Paths::CHAT_TEMPLATES_DIR", root / "chat-templates")
        stub_const("Mimic::Paths::GENERATED_TEMPLATES_DIR", root / "chat-templates" / "generated")

        model = root / "Guarded-Q4_K_M.gguf"
        GgufWriter.write(model, { "general.architecture" => "qwen3",
                                  "tokenizer.chat_template" => GUARDED_TEMPLATE })
        allow(File).to receive(:file?).and_call_original
        allow(File).to receive(:file?).with("/bin/llama-server").and_return(true)

        cfg = {
          "model" => { "path" => model.to_s, "context_length" => 1000, "temperature" => 0.6,
                        "top_p" => 0.9, "top_k" => 20, "min_p" => 0.0, "presence_penalty" => 1.0, "repeat_penalty" => 1.0 },
          "llama" => { "binary" => "/bin/llama-server", "flash_attn" => "on", "cache_type" => "q8_0",
                        "host" => "127.0.0.1", "port" => 8080 },
        }
        expect { described_class.new(Mimic::LlmConfig::Settings.new(cfg)).render_preset(0) }
          .to output(/sanitized|can throw/).to_stdout

        generated = root / "chat-templates" / "generated" / "Guarded.jinja"
        expect(generated.read).not_to include("raise_exception")
        expect(launch_record.read).to include("--chat-template-file #{generated}")
      end
    end
  end
end
