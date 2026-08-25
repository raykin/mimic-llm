require_relative "../../lib/mimic"
require_relative "../../lib/mimic/llm_cli/models_table"
require_relative "../support/gguf_writer"
require "tmpdir"
require "fileutils"

RSpec.describe Mimic::LlmCli::ModelsTable do
  def table(cfg, scan)
    described_class.new(Mimic::LlmConfig::Settings.new(cfg), scan)
  end

  def capture_stdout
    previous = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = previous
  end

  describe "#render" do
    it "does not crash when the active model path no longer exists on disk" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        present = root / "present.gguf"
        FileUtils.touch(present)

        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])
        stub_const("Mimic::LlmConfig::MODEL_CTX_PATH", root / "model-ctx.json")
        stub_const("Mimic::Model::Memory::N_CPU_MOE_PATH", root / "ik-n-cpu-moe.json")
        allow_any_instance_of(Mimic::Model::Header).to receive(:moe?).and_return(nil)

        instance = table({ "model" => { "path" => (root / "gone.gguf").to_s } },
                         Mimic::Model.pair([[present, root]]))

        expect { instance.render }.not_to raise_error
      end
    end

    it "attaches the projector to its model instead of listing it, and marks it" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        model = root / "model.gguf"
        projector = root / "mmproj-F32.gguf"
        FileUtils.touch(model)
        GgufWriter.write(projector, { "general.type" => "mmproj" })

        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])
        stub_const("Mimic::LlmConfig::MODEL_CTX_PATH", root / "model-ctx.json")
        stub_const("Mimic::Model::Memory::N_CPU_MOE_PATH", root / "ik-n-cpu-moe.json")
        allow_any_instance_of(Mimic::Model::Header).to receive(:moe?).and_return(nil)

        instance = table({ "model" => { "path" => model.to_s } },
                         Mimic::Model.pair([[model, root], [projector, root]]))

        rendered = capture_stdout { instance.render }
        row = rendered.lines.find { |line| line.include?("model") }

        expect(rendered).not_to include("mmproj")
        expect(row).to include("✓")
      end
    end

    # `llm setup` skips these, so the board has to say why they are missing
    # from the picker rather than leaving them looking eligible.
    it "marks an embedding model" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        model = root / "bge-m3-Q8_0.gguf"
        FileUtils.touch(model)

        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])
        stub_const("Mimic::LlmConfig::MODEL_CTX_PATH", root / "model-ctx.json")
        stub_const("Mimic::Model::Memory::N_CPU_MOE_PATH", root / "ik-n-cpu-moe.json")
        allow_any_instance_of(Mimic::Model::Header).to receive(:moe?).and_return(nil)
        allow_any_instance_of(Mimic::Model::Header).to receive(:embedding?).and_return(true)

        instance = table({ "model" => { "path" => model.to_s } }, Mimic::Model.pair([[model, root]]))
        rendered = capture_stdout { instance.render }
        row = rendered.lines.find { |line| line.include?("bge-m3") }

        expect(rendered).to include("Embed")
        expect(row).to include("✓")
      end
    end

    it "leaves the vision mark empty for a model with no projector" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        model = root / "model.gguf"
        FileUtils.touch(model)

        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])
        stub_const("Mimic::LlmConfig::MODEL_CTX_PATH", root / "model-ctx.json")
        stub_const("Mimic::Model::Memory::N_CPU_MOE_PATH", root / "ik-n-cpu-moe.json")
        allow_any_instance_of(Mimic::Model::Header).to receive(:moe?).and_return(nil)

        instance = table({ "model" => { "path" => model.to_s } }, Mimic::Model.pair([[model, root]]))
        rendered = capture_stdout { instance.render }
        row = rendered.lines.find { |line| line.include?("model") }

        expect(row).not_to include("✓")
      end
    end

    it "leaves the upstream column out when no client was given" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        model = root / "model.gguf"
        FileUtils.touch(model)

        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])
        stub_const("Mimic::LlmConfig::MODEL_CTX_PATH", root / "model-ctx.json")
        stub_const("Mimic::Model::Memory::N_CPU_MOE_PATH", root / "ik-n-cpu-moe.json")
        allow_any_instance_of(Mimic::Model::Header).to receive(:moe?).and_return(nil)

        instance = table({ "model" => { "path" => model.to_s } }, Mimic::Model.pair([[model, root]]))

        expect(capture_stdout { instance.render }).not_to include("Upstream")
      end
    end

    it "renders the upstream verdict when a client is given" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir) / "Qwen3.8-27B-GGUF"
        root.mkpath
        model = root / "model.gguf"
        GgufWriter.write(model, { "general.repo_url" => "https://huggingface.co/unsloth" })

        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])
        stub_const("Mimic::LlmConfig::MODEL_CTX_PATH", root / "model-ctx.json")
        stub_const("Mimic::Model::Memory::N_CPU_MOE_PATH", root / "ik-n-cpu-moe.json")
        allow_any_instance_of(Mimic::Model::Header).to receive(:moe?).and_return(nil)

        client = instance_double(Mimic::Util::Hf)
        allow(client).to receive(:tree).with("unsloth/Qwen3.8-27B-GGUF")
                                      .and_return([{ "path" => "model.gguf", "size" => model.size + 1,
                                                     "lastCommit" => { "date" => "2026-08-14T16:04:14.000Z" } }])

        instance = described_class.new(
          Mimic::LlmConfig::Settings.new({ "model" => { "path" => model.to_s } }),
          Mimic::Model.pair([[model, root]]),
          client: client
        )
        rendered = capture_stdout { instance.render }

        expect(rendered).to include("Upstream")
        expect(rendered).to include("stale 2026-08-14")
      end
    end

    it "explains the ? verdict under the board and only when checking" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        model = root / "model.gguf"
        FileUtils.touch(model)

        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])
        stub_const("Mimic::LlmConfig::MODEL_CTX_PATH", root / "model-ctx.json")
        stub_const("Mimic::Model::Memory::N_CPU_MOE_PATH", root / "ik-n-cpu-moe.json")
        allow_any_instance_of(Mimic::Model::Header).to receive(:moe?).and_return(nil)
        settings = Mimic::LlmConfig::Settings.new({ "model" => { "path" => model.to_s } })
        scan = Mimic::Model.pair([[model, root]])

        checked = capture_stdout { described_class.new(settings, scan, client: instance_double(Mimic::Util::Hf)).render }
        plain = capture_stdout { described_class.new(settings, scan).render }

        expect(checked).to include("?")
        expect(checked).to include("no source repo")
        expect(plain).not_to include("no source repo")
      end
    end

    it "reports the search paths when nothing was found" do
      stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [Pathname.new("/opt/models")])

      expect { table({}, []).render }.to output(/No .gguf files found.*\/opt\/models/m).to_stdout
    end
  end
end
