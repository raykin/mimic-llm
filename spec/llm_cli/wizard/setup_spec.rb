require_relative "../../../lib/mimic"
require_relative "../../../lib/mimic/llm_cli/wizard/setup"
require_relative "../../support/gguf_writer"
require "tmpdir"
require "fileutils"

RSpec.describe Mimic::LlmCli::Wizard::Setup do
  def wizard(cfg = { "model" => {}, "llama" => {} }, prompt: instance_double(Mimic::Ui::Prompt))
    described_class.new(Mimic::LlmConfig::Settings.new(cfg), prompt: prompt)
  end

  describe "#choose_reasoning" do
    it "defaults to on" do
      prompt = instance_double(Mimic::Ui::Prompt)
      allow(prompt).to receive(:yes?).and_return(true)
      cfg = { "model" => {}, "llama" => {} }

      wizard(cfg, prompt: prompt).choose_reasoning

      expect(cfg["model"]).to include("reasoning" => "auto")
    end

    it "records the choice when the user turns it off" do
      cfg = { "model" => { "reasoning" => "auto" }, "llama" => {} }

      wizard(cfg, prompt: instance_double(Mimic::Ui::Prompt, yes?: false)).choose_reasoning

      expect(cfg["model"]).to include("reasoning" => "off")
    end
  end

  describe "#choose_engine" do
    def engine_prompt(picked)
      instance_double(Mimic::Ui::Prompt).tap do |prompt|
        allow(prompt).to receive(:select) { |_, choices, **opts| @choices = choices; @default = opts[:default]; picked }
      end
    end

    it "offers every engine that can be built" do
      prompt = engine_prompt("llama.cpp")
      wizard({ "model" => {}, "llama" => {} }, prompt: prompt).choose_engine

      expect(@choices.map { |c| c[:value] }).to eq(Mimic::EngineCli::Registry.names)
    end

    it "defaults to the configured engine" do
      prompt = engine_prompt("prism-llama.cpp")
      config = wizard({ "model" => {}, "llama" => { "engine" => "prism-llama.cpp" } }, prompt: prompt).choose_engine

      expect(@default).to eq(3)
      expect(config).to eq("prism-llama.cpp")
    end
  end

  describe "#chat_models" do
    def models_dir
      root = Pathname.new(Dir.mktmpdir)
      GgufWriter.write(root / "plain.gguf", { "general.architecture" => "llama" },
                       tensors: [["blk.0.attn_q.weight", 4096, 12, 4096]])
      GgufWriter.write(root / "bonsai-g128.gguf", { "general.architecture" => "qwen35" },
                       tensors: [["blk.0.attn_q.weight", 34_000, 42, 128_000]])
      GgufWriter.write(root / "bonsai-g64.gguf", { "general.architecture" => "qwen35" },
                       tensors: [["blk.0.attn_q.weight", 18_000, 42, 64_000]])
      root
    end

    def offered(engine, root)
      stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])
      cfg = { "model" => { "search_paths" => [] }, "llama" => { "engine" => engine } }
      wizard(cfg).chat_models.map { |m| m.path.basename.to_s }
    end

    it "hides the fork's ternary packing from upstream llama.cpp" do
      root = models_dir

      expect(offered("llama.cpp", root)).to contain_exactly("plain.gguf", "bonsai-g64.gguf")
    end

    it "offers the prism fork only its own G128 ternary models, not plain GGUFs too" do
      root = models_dir

      expect(offered("prism-llama.cpp", root)).to contain_exactly("bonsai-g128.gguf")
    end

    it "names the models it hid rather than letting them vanish" do
      root = models_dir
      stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])
      cfg = { "model" => { "search_paths" => [] }, "llama" => { "engine" => "llama.cpp" } }
      prompt = instance_double(Mimic::Ui::Prompt)
      allow(prompt).to receive(:select).and_return((root / "plain.gguf").to_s)

      expect { wizard(cfg, prompt: prompt).choose_model }
        .to output(/hidden .*bonsai-g128\.gguf/).to_stdout
    end

    it "hides every ternary packing from ik_llama.cpp, which has no Q2_0 at all" do
      root = models_dir

      expect(offered("ik_llama.cpp", root)).to contain_exactly("plain.gguf")
    end

    it "explains a plain GGUF hidden from prism as not-Prism-exclusive, not unreadable" do
      root = models_dir
      stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])
      cfg = { "model" => { "search_paths" => [] }, "llama" => { "engine" => "prism-llama.cpp" } }
      prompt = instance_double(Mimic::Ui::Prompt)
      allow(prompt).to receive(:select).and_return((root / "bonsai-g128.gguf").to_s)

      expect { wizard(cfg, prompt: prompt).choose_model }
        .to output(/hidden -- not a Prism G128 ternary model.*plain\.gguf/).to_stdout
    end
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

        expect(found.map { |m| m.path.to_s }).to eq([(root / "real.gguf").to_s])
      end
    end

    it "collects .gguf files from every scan dir that exists" do
      Dir.mktmpdir do |tmp|
        root = Pathname.new(tmp)
        FileUtils.touch(root / "b.gguf")
        FileUtils.touch(root / "a.gguf")
        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])

        expect(wizard.scan_gguf.map { |m| m.path.to_s })
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

        expect(found.map { |m| m.path.to_s }).to eq([(root / "nested/model.gguf").to_s])
      end
    end

    it "attaches an mmproj file to its model instead of listing it as one" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        FileUtils.touch(root / "model.gguf")
        GgufWriter.write(root / "mmproj-model.gguf", { "general.type" => "mmproj" })
        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])

        found = wizard.scan_gguf

        expect(found.map { |m| m.path.basename.to_s }).to contain_exactly("model.gguf")
        expect(found.first.projector).to eq(root / "mmproj-model.gguf")
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
        instance = wizard(prompt: instance_double(Mimic::Ui::Prompt, ask: "~/typed.gguf"))

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
        instance = wizard(prompt: instance_double(Mimic::Ui::Prompt, ask: (root / "alias/model.gguf").to_s))

        expect(instance.select_model(nil)).to eq(target.realpath.to_s)
      end
    end

    def labelled(moe:)
      Dir.mktmpdir do |dir|
        path = Pathname.new(dir) / "sub/model.gguf"
        path.dirname.mkpath
        FileUtils.touch(path)
        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [])
        allow(Mimic::Model::Schema).to receive(:moe?).with(path.realpath.to_s, meta: anything).and_return(moe)
        prompt = instance_double(Mimic::Ui::Prompt)
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

    # An embedding model has no chat template and serves no completions, so
    # picking one here boots a server every agent then fails against.
    it "does not offer an embedding model" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir) / "sub"
        root.mkpath
        GgufWriter.write(root / "chat-Q4_K_M.gguf", { "general.architecture" => "qwen3", "qwen3.block_count" => 48 })
        GgufWriter.write(root / "bge-m3-Q8_0.gguf", { "general.architecture" => "bert", "bert.attention.causal" => 0 })
        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])
        prompt = instance_double(Mimic::Ui::Prompt)
        allow(prompt).to receive(:select) { |_, choices, **| choices.first }

        wizard(prompt: prompt).select_model(nil)

        expect(prompt).to have_received(:select)
          .with("GGUF model file:", ["sub/chat-Q4_K_M.gguf", "Enter a path manually..."], any_args)
      end
    end
  end

  describe "#embedding_models" do
    it "keeps only the embedding models the scan found" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        GgufWriter.write(root / "chat-Q4_K_M.gguf", { "general.architecture" => "qwen3", "qwen3.block_count" => 48 })
        GgufWriter.write(root / "bge-m3-Q8_0.gguf", { "general.architecture" => "bert", "bert.attention.causal" => 0 })
        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])

        expect(wizard.embedding_models.map { |m| m.path.basename.to_s }).to eq(["bge-m3-Q8_0.gguf"])
      end
    end
  end

  describe "#choose_mmproj" do
    # A model switch away from a vision model previously left the old
    # projector wired into config -- ik_llama would boot the new (unrelated)
    # text model with the old model's --mmproj still pointed at it, burning
    # ~1.6 GB of VRAM on a projector that serves nothing.
    around do |example|
      Dir.mktmpdir do |dir|
        @mmproj_store_dir = Pathname.new(dir) / "llm-config"
        example.run
      end
    end

    before do
      stub_const("Mimic::LlmConfig::LLM_CONFIG_DIR", @mmproj_store_dir)
      stub_const("Mimic::LlmConfig::MODEL_MMPROJ_PATH", @mmproj_store_dir / "model-mmproj.json")
    end

    it "leaves mmproj_path nil when the model has no projector" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        FileUtils.touch(root / "text-only.gguf")

        instance = wizard({
                             "model" => { "path" => (root / "text-only.gguf").to_s },
                             "llama" => {},
                           })

        instance.choose_mmproj

        expect(instance.config.model.mmproj_path).to be_nil
      end
    end

    it "sets mmproj_path when the new model has a matching projector and the user accepts" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        FileUtils.touch(root / "vision.gguf")
        GgufWriter.write(root / "mmproj-vision.gguf", { "general.type" => "mmproj" })

        instance = wizard(
          { "model" => { "path" => (root / "vision.gguf").to_s }, "llama" => {} },
          prompt: instance_double(Mimic::Ui::Prompt, yes?: true),
        )

        instance.choose_mmproj

        expect(instance.config.model.mmproj_path).to eq((root / "mmproj-vision.gguf").to_s)
      end
    end
  end

  describe "#choose_context" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = Pathname.new(dir)
        example.run
      end
    end

    before do
      stub_const("Mimic::LlmConfig::MODEL_CTX_PATH", @dir / "model-ctx.json")
      stub_const("Mimic::LlmConfig::MODEL_COMPUTE_PATH", @dir / "model-compute.json")
      stub_const("Mimic::Model::N_CPU_MOE_PATH", @dir / "ik-n-cpu-moe.json")
    end

    def cfg = { "model" => { "path" => "/m.gguf", "context_length" => 1000 }, "llama" => { "cache_type" => "q8_0" } }

    def ik_cfg = { "model" => { "path" => "/m.gguf", "context_length" => 1000 },
                   "llama" => { "cache_type" => "q8_0", "engine" => "ik_llama.cpp" } }

    def picking_prompt
      instance_double(Mimic::Ui::Prompt).tap do |prompt|
        allow(prompt).to receive(:select).and_return(described_class::CONTEXT_PRESETS.keys.first)
      end
    end

    it "accepts without prompting when the estimate can't be computed" do
      allow_any_instance_of(Mimic::Model).to receive(:preflight).and_return(nil)

      expect { wizard(cfg, prompt: picking_prompt).choose_context }.not_to raise_error
    end

    # A past launch measured what this model really costs beyond weights+KV;
    # the preflight budgets against that instead of Model::Vram.compute_default.
    it "passes the measured compute cost to the estimate when one was recorded" do
      Mimic::Model.new("/m.gguf").remember_compute(60_000, "q8_0", 1712)
      expect_any_instance_of(Mimic::Model).to receive(:preflight)
        .with(anything, anything, compute_mib: 1712)
        .and_return(fits: true, need_mib: 1000, total_mib: 24_000, max_ctx: 5000)

      expect { wizard(cfg, prompt: picking_prompt).choose_context }.to output(/VRAM ok/).to_stdout
    end

    it "accepts without prompting when the estimate fits" do
      allow_any_instance_of(Mimic::Model).to receive(:preflight)
        .and_return(fits: true, need_mib: 1000, total_mib: 24_000, max_ctx: 5000)

      settings = nil
      expect { settings = wizard(cfg, prompt: picking_prompt).choose_context }.to output(/VRAM ok/).to_stdout
      expect(settings.model.context_length).to eq(60_000)
    end

    # A MoE model has a lever the warning never offered: move experts to the
    # CPU until the rest fits. Only ik_llama takes --n-cpu-moe.
    it "offloads MoE experts instead of warning when that closes the gap" do
      allow_any_instance_of(Mimic::Model).to receive(:preflight).and_return(
        { fits: false, need_mib: 23_100, weights_mib: 19_000, kv_mib: 2_000, budget_mib: 22_528, total_mib: 24_576, max_ctx: 140_000 },
      )
      allow(Mimic::Model::Vram).to receive(:layers_to_offload).and_return(2)
      prompt = picking_prompt

      expect { wizard(ik_cfg, prompt: prompt).choose_context }.to output(/offloading 2 layer/).to_stdout

      expect(Mimic::Model.new("/m.gguf").n_cpu_moe).to eq(2)
      expect(prompt).to have_received(:select).once
    end

    it "still warns when offloading cannot close the gap" do
      allow_any_instance_of(Mimic::Model).to receive(:preflight).and_return(
        { fits: false, need_mib: 40_000, weights_mib: 30_000, kv_mib: 8_000, budget_mib: 22_528, total_mib: 24_576, max_ctx: 500 },
        { fits: true, need_mib: 1000, total_mib: 24_576, max_ctx: 5000 },
      )
      allow(Mimic::Model::Vram).to receive(:layers_to_offload).and_return(nil)
      prompt = picking_prompt
      allow(prompt).to receive(:yes?).and_return(false)

      expect { wizard(ik_cfg, prompt: prompt).choose_context }.to output(/won't fully fit VRAM/).to_stdout
    end

    it "warns rather than offloading on llama.cpp, which is all-GPU by design" do
      allow_any_instance_of(Mimic::Model).to receive(:preflight).and_return(
        { fits: false, need_mib: 23_100, weights_mib: 19_000, kv_mib: 2_000, budget_mib: 22_528, total_mib: 24_576, max_ctx: 140_000 },
        { fits: true, need_mib: 1000, total_mib: 24_576, max_ctx: 5000 },
      )
      allow(Mimic::Model::Vram).to receive(:layers_to_offload).and_return(2)
      prompt = picking_prompt
      allow(prompt).to receive(:yes?).and_return(false)

      expect { wizard(cfg, prompt: prompt).choose_context }.to output(/won't fully fit VRAM/).to_stdout
      expect(Mimic::Model::Vram).not_to have_received(:layers_to_offload)
    end

    it "re-picks when the user declines an over-committed context" do
      allow_any_instance_of(Mimic::Model).to receive(:preflight).and_return(
        { fits: false, need_mib: 30_000, weights_mib: 20_000, kv_mib: 8_000, budget_mib: 23_000, total_mib: 24_000, max_ctx: 500 },
        { fits: true, need_mib: 1000, total_mib: 24_000, max_ctx: 5000 },
      )
      prompt = picking_prompt
      allow(prompt).to receive(:yes?).and_return(false)

      expect { wizard(cfg, prompt: prompt).choose_context }.to output(/won't fully fit VRAM/).to_stdout
      expect(prompt).to have_received(:select).twice
    end
  end

  describe "#step" do
    it "numbers steps against the total it was given" do
      instance = wizard
      expect { instance.step("First") }.to output(%r{Step 1/6}).to_stdout
      expect { instance.step("Second") }.to output(%r{Step 2/6}).to_stdout
    end

    it "counts against a caller-supplied total" do
      instance = described_class.new({}, total: 7, prompt: instance_double(Mimic::Ui::Prompt))
      expect { instance.step("First") }.to output(/Step 1\/7/).to_stdout
    end
  end
end
