require_relative "../../lib/mimic"
require_relative "../../lib/mimic/engine_cli/status"
require_relative "../support/gguf_writer"
require "tmpdir"

RSpec.describe Mimic::EngineCli::Status do
  def status(cfg)
    described_class.new(Mimic::LlmConfig::Settings.new(cfg))
  end

  def ik_config(overrides = {})
    { "model" => { "path" => "/m/Ornith-1.0-35B-UD-IQ4_NL.gguf", "context_length" => 160_000 },
      "llama" => { "engine" => "ik_llama.cpp", "cache_type" => "q8_0", "port" => 8080, "n_slots" => 1 } }
      .merge(overrides)
  end

  def with_launch_record(argv)
    Dir.mktmpdir do |dir|
      record = Pathname.new(dir) / "ik-llama-launch.txt"
      record.write("#{argv}\n")
      stub_const("Mimic::Engine::IkLlama::LAUNCH_RECORD", record)
      allow(Mimic::Engine::Base).to receive(:pid_file).and_return(Pathname.new(dir) / "absent.pid")
      yield
    end
  end

  before { allow(Mimic::Util::Probes).to receive(:http_ok).and_return(true) }

  describe "#print" do
    it "reports the offloaded MoE layers the running ik server was launched with" do
      with_launch_record("llama-server -c 120000 -ctk q8_0 -np 1 --n-cpu-moe 16") do
        expect { status(ik_config).print }.to output(/CPU MoE:\s+16 layers/).to_stdout
      end
    end

    it "says all layers are on the GPU when ik was launched without the flag" do
      with_launch_record("llama-server -c 160000 -ctk q8_0 -np 1") do
        expect { status(ik_config).print }.to output(/CPU MoE:\s+none/).to_stdout
      end
    end

    it "takes ctx and KV from the launch record, not the config, on ik" do
      with_launch_record("llama-server -c 120000 -ctk q4_0 -np 2") do
        rendered = capture { status(ik_config).print }

        expect(rendered).to match(/Context:\s+120,000/)
        expect(rendered).to match(/KV cache:\s+q4_0/)
        expect(rendered).not_to include("couldn't confirm")
      end
    end

    it "falls back to the config when ik has no launch record" do
      Dir.mktmpdir do |dir|
        stub_const("Mimic::Engine::IkLlama::LAUNCH_RECORD", Pathname.new(dir) / "gone.txt")
        allow(Mimic::Engine::Base).to receive(:pid_file).and_return(Pathname.new(dir) / "absent.pid")
        rendered = capture { status(ik_config).print }

        expect(rendered).to include("couldn't confirm")
        expect(rendered).to match(/Context:\s+160,000/)
      end
    end

    # The record is written by the real engine rather than a literal argv, so
    # a flag renamed on the build side without the read-back following shows
    # up here as config values standing in for the live ones.
    it "reads back the argv the ik engine actually built" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        stub_const("Mimic::Paths::LLM_RUN_DIR", root)
        stub_const("Mimic::Engine::IkLlama::LAUNCH_RECORD", root / "ik-llama-launch.txt")
        allow(Mimic::Engine::Base).to receive(:pid_file).and_return(root / "absent.pid")
        stub_const("Mimic::Paths::CHAT_TEMPLATES_DIR", root / "no-templates")
        allow(File).to receive(:file?).and_call_original
        allow(File).to receive(:file?).with("/bin/llama-server").and_return(true)
        settings = Mimic::LlmConfig::Settings.new(
          ik_config("llama" => { "engine" => "ik_llama.cpp", "binary" => "/bin/llama-server",
                                 "cache_type" => "q4_0", "port" => 8080, "n_slots" => 3 }),
        )
        Mimic::Engine::IkLlama.new(settings).render_preset(12)

        rendered = capture { described_class.new(settings).print }

        expect(rendered).to match(/Context:\s+160,000/)
        expect(rendered).to match(/KV cache:\s+q4_0/)
        expect(rendered).to match(/CPU MoE:\s+12 layers/)
      end
    end

    it "reports vision, reasoning and sampling from the ik launch record" do
      record = "llama-server -c 160000 -ctk q8_0 -np 1 --reasoning off --mmproj /m/mmproj-F16.gguf " \
               "--temp 0.6 --top-k 20 --top-p 0.95 --min-p 0.0 --presence-penalty 1.5 --repeat-penalty 1.05"
      with_launch_record(record) do
        rendered = capture { status(ik_config).print }

        expect(rendered).to match(%r{Vision:\s+on \(mmproj-F16\.gguf\)})
        expect(rendered).to match(/Reasoning:\s+off/)
        expect(rendered).to match(/Sampling:\s+temp 0\.6\s+top-p 0\.95\s+top-k 20\s+min-p 0\.0\s+presence 1\.5\s+repeat 1\.05/)
      end
    end

    it "says vision is off when the running server was launched without a projector" do
      with_launch_record("llama-server -c 160000 -ctk q8_0 -np 1") do
        expect { status(ik_config).print }.to output(/Vision:\s+off/).to_stdout
      end
    end

    # llama.cpp's router re-emits the preset's `temp` key as `--temperature`,
    # while ik's launch record keeps the `--temp` spelling the engine was
    # given. Reading only one of them shows the config value on the other.
    it "accepts the --temperature spelling llama.cpp reports" do
      Dir.mktmpdir do |dir|
        allow(Mimic::Engine::Base).to receive(:pid_file).and_return(Pathname.new(dir) / "absent.pid")
        allow(Mimic::Util::Probes).to receive(:http_json).and_return(
          { "data" => [{ "id" => "model", "status" => { "value" => "loaded",
                                                        "args" => ["--ctx-size", "8192", "--temperature", "1.0",
                                                                   "--reasoning", "auto",
                                                                   "--mmproj", "/m/mmproj-F32.gguf"] } }] }
        )
        cfg = { "model" => { "path" => "/m/model-Q4_K_M.gguf", "context_length" => 4096, "reasoning" => "off" },
                "llama" => { "engine" => "llama.cpp", "cache_type" => "q8_0", "port" => 8080, "n_slots" => 1 } }
        rendered = capture { status(cfg).print }

        expect(rendered).to match(/Sampling:\s+temp 1\.0/)
        expect(rendered).to match(/Reasoning:\s+off/)
        expect(rendered).to match(%r{Vision:\s+on \(mmproj-F32\.gguf\)})
      end
    end

    it "falls back to the configured reasoning and sampling when the server is stopped" do
      Dir.mktmpdir do |dir|
        allow(Mimic::Util::Probes).to receive(:http_ok).and_return(false)
        allow(Mimic::Engine::Base).to receive(:pid_file).and_return(Pathname.new(dir) / "absent.pid")
        cfg = ik_config
        cfg["model"] = cfg["model"].merge("reasoning" => "off")
        rendered = capture { status(cfg).print }

        expect(rendered).to match(/Reasoning:\s+off/)
        expect(rendered).to match(/Sampling:\s+temp 0\.8\s+top-p 0\.95\s+top-k 40/)
        expect(rendered).to match(/Vision:\s+off/)
      end
    end

    it "leaves the CPU MoE line off for llama.cpp, which has no such flag" do
      Dir.mktmpdir do |dir|
        allow(Mimic::Engine::Base).to receive(:pid_file).and_return(Pathname.new(dir) / "absent.pid")
        allow(Mimic::Util::Probes).to receive(:http_json).and_return(
          { "data" => [{ "id" => "model", "status" => { "value" => "loaded",
                                                        "args" => ["--ctx-size", "8192", "--parallel", "4"] } }] }
        )
        cfg = { "model" => { "path" => "/m/model-Q4_K_M.gguf", "context_length" => 4096 },
                "llama" => { "engine" => "llama.cpp", "cache_type" => "q8_0", "port" => 8080, "n_slots" => 1 } }
        rendered = capture { status(cfg).print }

        expect(rendered).not_to include("CPU MoE")
        expect(rendered).to match(/Context:\s+8,192/)
      end
    end
  end

  describe "thinking lines" do
    around do |example|
      Dir.mktmpdir do |dir|
        @root = Pathname.new(dir)
        example.run
      end
    end

    before do
      stub_const("Mimic::Paths::CHAT_TEMPLATES_DIR", @root / "chat-templates")
      stub_const("Mimic::Paths::GENERATED_TEMPLATES_DIR", @root / "chat-templates/generated")
      stub_const("Mimic::LlmConfig::MODEL_EFFORT_PATH", @root / "model-effort.json")
      allow(Mimic::Engine::Base).to receive(:pid_file).and_return(@root / "absent.pid")
    end

    let(:thinking_template) do
      "{%- if enable_thinking %}{%- endif %}{%- set r = reasoning_effort|default('xhigh') %}" \
        "{%- if r not in ('xhigh', 'medium', 'low') %}{%- endif %}"
    end

    def model_with(template)
      path = @root / "Thinker-Q4_K_M.gguf"
      keys = { "general.architecture" => "qwen3" }
      keys["tokenizer.chat_template"] = template if template
      GgufWriter.write(path, keys)
      path.to_s
    end

    def llama_config(model_path, model = {})
      { "model" => { "path" => model_path, "context_length" => 4096 }.merge(model),
        "llama" => { "engine" => "llama.cpp", "cache_type" => "q8_0", "port" => 8080, "n_slots" => 1 } }
    end

    def serving(cfg, args)
      allow(Mimic::Util::Probes).to receive(:http_json).and_return(
        { "data" => [{ "id" => Mimic::LlmConfig::Settings.new(cfg).model.name, "status" => { "value" => "loaded", "args" => args } }] },
      )
    end

    def stopped = allow(Mimic::Util::Probes).to receive(:http_ok).and_return(false)

    it "resolves auto to on and shows the level llama.cpp was started with" do
      cfg = llama_config(model_with(thinking_template))
      serving(cfg, ["--ctx-size", "4096", "--reasoning", "auto", "--reasoning-effort", "low"])
      rendered = capture { status(cfg).print }

      expect(rendered).to match(/Reasoning:\s+on$/)
      expect(rendered).to match(/Thinking:\s+low$/)
    end

    it "resolves auto to off for a template with no thinking switch" do
      stopped
      rendered = capture { status(llama_config(model_with("{{ messages }}"))).print }

      expect(rendered).to match(/Reasoning:\s+off$/)
      expect(rendered).to match(/Thinking:\s+off$/)
    end

    it "names the template default when no level was picked" do
      stopped
      rendered = capture { status(llama_config(model_with(thinking_template))).print }

      expect(rendered).to match(/Thinking:\s+xhigh \(template default\)/)
    end

    it "shows the picked level when the server is stopped" do
      stopped
      settings = Mimic::LlmConfig::Settings.new(llama_config(model_with(thinking_template)))
      settings.model.file.memory.effort = "medium"
      rendered = capture { described_class.new(settings).print }

      expect(rendered).to match(/Thinking:\s+medium$/)
    end

    it "says so when thinking is on but the template has no levels" do
      stopped
      rendered = capture { status(llama_config(model_with("{%- if enable_thinking %}{%- endif %}"))).print }

      expect(rendered).to match(/Reasoning:\s+on$/)
      expect(rendered).to match(/Thinking:\s+the chat template has no levels/)
    end

    it "reads the level out of ik's --chat-template-kwargs" do
      record = @root / "ik-llama-launch.txt"
      record.write(%(llama-server -c 4096 -np 1 --reasoning auto --chat-template-kwargs {"reasoning_effort":"medium"}\n))
      stub_const("Mimic::Engine::IkLlama::LAUNCH_RECORD", record)
      cfg = llama_config(model_with(thinking_template))
      cfg["llama"] = cfg["llama"].merge("engine" => "ik_llama.cpp")
      rendered = capture { status(cfg).print }

      expect(rendered).to match(/Thinking:\s+medium$/)
    end
  end

  def capture
    previous = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = previous
  end
end
