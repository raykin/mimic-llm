require_relative "../../lib/mimic"
require_relative "../../lib/mimic/engine_cli/status"
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
        expect(rendered).to match(/KV cache: q4_0/)
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
        expect(rendered).to match(/KV cache: q4_0/)
        expect(rendered).to match(/CPU MoE:\s+12 layers/)
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

  def capture
    previous = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = previous
  end
end
