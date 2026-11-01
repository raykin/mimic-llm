require_relative "../../../lib/mimic"
require_relative "../../../lib/mimic/llm_cli/wizard/setup"
require_relative "../../support/gguf_writer"
require "tmpdir"
require "fileutils"

RSpec.describe Mimic::LlmCli::Wizard::Setup do
  around do |example|
    Dir.mktmpdir do |dir|
      @packing_store = Pathname.new(dir) / "model-packing.json"
      example.run
    end
  end

  before { stub_const("Mimic::Model::Memory::TERNARY_PACKING_PATH", @packing_store) }

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

  describe "#choose_effort" do
    around do |example|
      Dir.mktmpdir do |dir|
        @effort_dir = Pathname.new(dir)
        example.run
      end
    end

    before do
      stub_const("Mimic::Paths::CHAT_TEMPLATES_DIR", @effort_dir / "chat-templates")
      stub_const("Mimic::Paths::GENERATED_TEMPLATES_DIR", @effort_dir / "chat-templates/generated")
    end

    def model_with(template)
      path = @effort_dir / "Thinker-Q4_K_M.gguf"
      keys = { "general.architecture" => "qwen3" }
      keys["tokenizer.chat_template"] = template if template
      GgufWriter.write(path, keys)
      path.to_s
    end

    def levelled_model
      model_with("{%- set r = reasoning_effort|default('xhigh') %}" \
                 "{%- if resolved_reasoning_effort not in ('xhigh', 'medium', 'low') %}{%- endif %}")
    end

    def picking_prompt(answer)
      instance_double(Mimic::Ui::Prompt).tap do |prompt|
        allow(prompt).to receive(:select) do |_, choices, **opts|
          @choices = choices
          @default = opts[:default]
          answer
        end
      end
    end

    it "offers the template's levels with the template's default preselected" do
      cfg = { "model" => { "path" => levelled_model, "reasoning" => "auto" }, "llama" => {} }

      config = wizard(cfg, prompt: picking_prompt("low")).choose_effort

      expect(@choices).to eq(%w[xhigh medium low])
      expect(@default).to eq("xhigh")
      expect(config.model.reasoning_effort).to eq("low")
    end

    it "skips the picker when thinking is off" do
      prompt = instance_double(Mimic::Ui::Prompt)
      cfg = { "model" => { "path" => levelled_model, "reasoning" => "off" }, "llama" => {} }

      config = nil
      expect { config = wizard(cfg, prompt: prompt).choose_effort }.to output(/thinking is off/).to_stdout
      expect(config.model.reasoning_effort).to be_nil
    end

    it "skips the picker and clears an old level when the template has no levels" do
      prompt = instance_double(Mimic::Ui::Prompt)
      cfg = { "model" => { "path" => model_with("{{ messages }}"), "reasoning" => "auto" }, "llama" => {} }

      config = nil
      expect { config = wizard(cfg, prompt: prompt).choose_effort }.to output(/no levels/).to_stdout
      expect(config.model.reasoning_effort).to be_nil
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
      prompt = engine_prompt("prism-v7-llama.cpp")
      config = wizard({ "model" => {}, "llama" => { "engine" => "prism-v7-llama.cpp" } }, prompt: prompt).choose_engine

      expect(@default).to eq(3)
      expect(config).to eq("prism-v7-llama.cpp")
    end

    it "offers the current Prism fork for Bonsai 2" do
      prompt = engine_prompt("prism-v7-llama.cpp")
      config = wizard({ "model" => {}, "llama" => {} }, prompt: prompt).choose_engine

      expect(@choices.find { |choice| choice[:value] == config }[:name]).to include("Bonsai 2 PQ2_0/PTQ1_0")
    end
  end

  describe "#report_hidden_models" do
    def models_dir
      root = Pathname.new(Dir.mktmpdir)
      GgufWriter.write(root / "plain.gguf", { "general.architecture" => "llama" },
                       tensors: [["blk.0.attn_q.weight", 4096, 12, 4096]])
      GgufWriter.write(root / "bonsai-g128.gguf", { "general.architecture" => "qwen35" },
                       tensors: [["blk.0.attn_q.weight", 34_000, 42, 128_000]])
      GgufWriter.write(root / "bonsai-2-pq2.gguf", { "general.architecture" => "qwen35" },
                       tensors: [["blk.0.attn_q.weight", 34_000, 142, 128_000]])
      root
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

    it "explains a plain GGUF hidden from prism as not-Prism-exclusive, not unreadable" do
      root = models_dir
      stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])
      cfg = { "model" => { "search_paths" => [] }, "llama" => { "engine" => "prism-v7-llama.cpp" } }
      prompt = instance_double(Mimic::Ui::Prompt)
      allow(prompt).to receive(:select).and_return((root / "bonsai-2-pq2.gguf").to_s)

      expect { wizard(cfg, prompt: prompt).choose_model }
        .to output(/hidden -- not a Prism Bonsai 2 ternary model.*plain\.gguf/).to_stdout
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
        allow_any_instance_of(Mimic::Model::Header).to receive(:moe?).and_return(moe)
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
      stub_const("Mimic::Model::Memory::N_CPU_MOE_PATH", @dir / "ik-n-cpu-moe.json")
    end

    def cfg = { "model" => { "path" => "/m.gguf", "context_length" => 1000 }, "llama" => { "cache_type" => "q8_0" } }

    def picking_prompt
      instance_double(Mimic::Ui::Prompt).tap do |prompt|
        allow(prompt).to receive(:select).and_return(described_class::CONTEXT_PRESETS.keys.first)
      end
    end

    it "labels presets with ctx and KV type alone" do
      expect(described_class::CONTEXT_PRESETS.keys).to all(match(/\A\d+ \/ \w+\z/))
    end

    it "keeps the preset the preflight accepted" do
      allow_any_instance_of(Mimic::LlmCli::Wizard::ContextPreflight).to receive(:ok?).and_return(true)

      settings = nil
      expect { settings = wizard(cfg, prompt: picking_prompt).choose_context }.to output.to_stdout

      expect(settings.model.context_length).to eq(60_000)
    end

    it "re-picks until the preflight accepts" do
      allow_any_instance_of(Mimic::LlmCli::Wizard::ContextPreflight).to receive(:ok?).and_return(false, true)
      prompt = picking_prompt

      expect { wizard(cfg, prompt: prompt).choose_context }.to output.to_stdout

      expect(prompt).to have_received(:select).twice
    end

    it "marks the preset matching the last good run" do
      Mimic::Model.new("/m.gguf").memory.remember_ctx(110_000, "q8_0")
      allow_any_instance_of(Mimic::LlmCli::Wizard::ContextPreflight).to receive(:ok?).and_return(true)
      prompt = picking_prompt

      expect { wizard(cfg, prompt: prompt).choose_context }.to output.to_stdout

      expect(prompt).to have_received(:select)
        .with("Context preset:", array_including("110000 / q8_0 -- last success run"), any_args)
    end

    it "leaves every other preset unmarked" do
      Mimic::Model.new("/m.gguf").memory.remember_ctx(110_000, "q8_0")
      allow_any_instance_of(Mimic::LlmCli::Wizard::ContextPreflight).to receive(:ok?).and_return(true)
      prompt = picking_prompt

      expect { wizard(cfg, prompt: prompt).choose_context }.to output.to_stdout

      expect(prompt).to have_received(:select) do |_, choices, _|
        expect(choices.grep(/last success run/).size).to eq(1)
      end
    end

    it "marks nothing when the model has no remembered run" do
      allow_any_instance_of(Mimic::LlmCli::Wizard::ContextPreflight).to receive(:ok?).and_return(true)
      prompt = picking_prompt

      expect { wizard(cfg, prompt: prompt).choose_context }.to output.to_stdout

      expect(prompt).to have_received(:select) do |_, choices, _|
        expect(choices.grep(/last success run/)).to be_empty
      end
    end

    it "falls back to a printed line when no preset matches the last good run" do
      Mimic::Model.new("/m.gguf").memory.remember_ctx(80_000, "q4_0")
      allow_any_instance_of(Mimic::LlmCli::Wizard::ContextPreflight).to receive(:ok?).and_return(true)

      expect { wizard(cfg, prompt: picking_prompt).choose_context }
        .to output(/Last good run for this model: 80,000 \/ q4_0/).to_stdout
    end

    it "prints no fallback line when a preset carries the marker" do
      Mimic::Model.new("/m.gguf").memory.remember_ctx(110_000, "q8_0")
      allow_any_instance_of(Mimic::LlmCli::Wizard::ContextPreflight).to receive(:ok?).and_return(true)

      expect { wizard(cfg, prompt: picking_prompt).choose_context }
        .not_to output(/Last good run for this model/).to_stdout
    end
  end

  describe "#step" do
    it "numbers steps against the total it was given" do
      instance = wizard
      expect { instance.step("First") }.to output(%r{Step 1/8}).to_stdout
      expect { instance.step("Second") }.to output(%r{Step 2/8}).to_stdout
    end

    it "counts against a caller-supplied total" do
      instance = described_class.new({}, total: 7, prompt: instance_double(Mimic::Ui::Prompt))
      expect { instance.step("First") }.to output(/Step 1\/7/).to_stdout
    end
  end
end
