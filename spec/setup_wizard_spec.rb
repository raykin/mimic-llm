require_relative "../lib/mimic"
require_relative "../lib/mimic/setup_wizard"
require "tmpdir"
require "fileutils"

RSpec.describe Mimic::SetupWizard do
  def wizard(cfg = { "model" => {}, "llama" => {} }, prompt: instance_double(TTY::Prompt))
    described_class.new(Mimic::LlmConfig::Settings.new(cfg), prompt: prompt)
  end

  describe "#scan_gguf" do
    # The picker must not offer a model whose symlink target is gone --
    # choosing it dies with "Model file not found" and exits the wizard.
    it "skips a dangling symlink" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        FileUtils.touch(root / "real.gguf")
        (root / "gone.gguf").make_symlink(root / "deleted.gguf")
        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [])

        found = wizard({ "model" => { "search_paths" => [root.to_s] } }).scan_gguf

        expect(found.map { |p, _| p.to_s }).to eq([(root / "real.gguf").to_s])
      end
    end

    it "collects .gguf files from every scan dir that exists" do
      Dir.mktmpdir do |tmp|
        root = Pathname.new(tmp)
        FileUtils.touch(root / "b.gguf")
        FileUtils.touch(root / "a.gguf")
        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])

        expect(wizard.scan_gguf.map { |p, _| p.to_s })
          .to eq([(root / "a.gguf").to_s, (root / "b.gguf").to_s])
      end
    end

    it "skips scan dirs that don't exist" do
      dir = instance_double(Pathname, directory?: false)
      stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [dir])
      expect(wizard.scan_gguf).to eq([])
    end

    it "scans the dirs LlmConfig resolves, recursively" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        (root / "nested").mkpath
        FileUtils.touch(root / "nested/model.gguf")
        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [])

        found = wizard({ "model" => { "search_paths" => [root.to_s] } }).scan_gguf

        expect(found.map { |p, _| p.to_s }).to eq([(root / "nested/model.gguf").to_s])
      end
    end

    it "skips a model whose basename marks it as a projector" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        FileUtils.touch(root / "model.gguf")
        FileUtils.touch(root / "mmproj-model.gguf")
        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])

        expect(wizard.scan_gguf.map { |p, _| p.basename.to_s }).to eq(["model.gguf"])
      end
    end
  end

  describe "#select_model" do
    # tty-prompt hands back the literal string typed; Ruby's File.file?
    # does not expand ~, so an unexpanded check rejects a real file.
    it "accepts a ~-prefixed path typed at the manual prompt" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        FileUtils.touch(root / "typed.gguf")
        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [])
        instance = wizard(prompt: instance_double(TTY::Prompt, ask: "~/typed.gguf"))

        # expand_path reads ENV["HOME"], not Dir.home -- stubbing the latter
        # leaves ~ unexpanded and the example dies on SystemExit.
        previous = ENV.fetch("HOME", nil)
        begin
          ENV["HOME"] = root.to_s
          expect(instance.select_model(nil)).to eq((root / "typed.gguf").realpath.to_s)
        ensure
          ENV["HOME"] = previous
        end
      end
    end

    # Finding A: Python returns Path(answer).expanduser().resolve(), so
    # ~/.llm/config.yaml and every cache keyed off it (model-ctx.json,
    # ik-n-cpu-moe.json) hold the real path. expand_path alone kept the
    # symlink and split those caches into two disagreeing key sets.
    it "resolves a symlinked model path to its target" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        target = root / "store/model.gguf"
        target.dirname.mkpath
        FileUtils.touch(target)
        (root / "alias").make_symlink(root / "store")

        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [])
        instance = wizard(prompt: instance_double(TTY::Prompt, ask: (root / "alias/model.gguf").to_s))

        expect(instance.select_model(nil)).to eq(target.realpath.to_s)
      end
    end

    def labelled(moe:)
      Dir.mktmpdir do |dir|
        path = Pathname.new(dir) / "sub/model.gguf"
        path.dirname.mkpath
        FileUtils.touch(path)
        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [])
        allow(Mimic::Vram).to receive(:moe?).with(path.realpath.to_s).and_return(moe)
        prompt = instance_double(TTY::Prompt)
        allow(prompt).to receive(:select) { |_, choices, **| choices.first }
        cfg = { "model" => { "search_paths" => [(path.dirname.dirname).to_s] }, "llama" => {} }

        wizard(cfg, prompt: prompt).select_model(nil)
        yield prompt
      end
    end

    it "tags a MoE model in the picker" do
      labelled(moe: true) do |prompt|
        expect(prompt).to have_received(:select).with("GGUF model file:", ["sub/model.gguf [MoE]", "Enter a path manually..."], any_args)
      end
    end

    it "leaves a non-MoE model untagged" do
      labelled(moe: false) do |prompt|
        expect(prompt).to have_received(:select).with("GGUF model file:", ["sub/model.gguf", "Enter a path manually..."], any_args)
      end
    end
  end

  describe "#choose_context" do
    def cfg = { "model" => { "path" => "/m.gguf", "context_length" => 1000 }, "llama" => { "cache_type" => "q8_0" } }

    def picking_prompt
      instance_double(TTY::Prompt).tap do |prompt|
        allow(prompt).to receive(:select).and_return(described_class::CONTEXT_PRESETS.keys.first)
      end
    end

    it "accepts without prompting when the estimate can't be computed" do
      allow(Mimic::Vram).to receive(:preflight).and_return(nil)
      allow(Mimic::LlmConfig).to receive(:recall_ctx).and_return(nil)

      expect { wizard(cfg, prompt: picking_prompt).choose_context }.not_to raise_error
    end

    it "accepts without prompting when the estimate fits" do
      allow(Mimic::Vram).to receive(:preflight).and_return(fits: true, need_mib: 1000, total_mib: 24_000, max_ctx: 5000)
      allow(Mimic::LlmConfig).to receive(:recall_ctx).and_return(nil)

      settings = nil
      expect { settings = wizard(cfg, prompt: picking_prompt).choose_context }.to output(/VRAM ok/).to_stdout
      expect(settings.context_length).to eq(60_000)
    end

    it "re-picks when the user declines an over-committed context" do
      allow(Mimic::LlmConfig).to receive(:recall_ctx).and_return(nil)
      allow(Mimic::Vram).to receive(:preflight).and_return(
        { fits: false, need_mib: 30_000, weights_mib: 20_000, kv_mib: 8_000, budget_mib: 23_000, total_mib: 24_000, max_ctx: 500 },
        { fits: true, need_mib: 1000, total_mib: 24_000, max_ctx: 5000 },
      )
      prompt = picking_prompt
      allow(prompt).to receive(:yes?).and_yield(double(default: nil)).and_return(false)

      expect { wizard(cfg, prompt: prompt).choose_context }.to output(/won't fully fit VRAM/).to_stdout
      expect(prompt).to have_received(:select).twice
    end
  end

  describe "#step" do
    it "numbers steps against the total it was given" do
      instance = wizard
      expect { instance.step("First") }.to output(/Step 1\/5/).to_stdout
      expect { instance.step("Second") }.to output(/Step 2\/5/).to_stdout
    end

    it "counts against a caller-supplied total" do
      instance = described_class.new({}, total: 7, prompt: instance_double(TTY::Prompt))
      expect { instance.step("First") }.to output(/Step 1\/7/).to_stdout
    end
  end
end
