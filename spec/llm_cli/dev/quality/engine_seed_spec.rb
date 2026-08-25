require_relative "../../../../lib/mimic"
require_relative "../../../../lib/mimic/llm_cli/dev/quality/engine_seed"
require "tmpdir"

RSpec.describe Mimic::LlmCli::Dev::Quality::EngineSeed do
  def seed_for(body)
    log = Pathname.new(@dir) / "local_quality.md"
    log.write(body)
    described_class.new(log)
  end

  around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

  describe "#best" do
    it "reads the engine out of a results header, keyed by the model's GGUF stem" do
      seed = seed_for(<<~LOG)
        ### Qwen3.8-27B - UD-IQ4_XS - llama.cpp - 110,080 ctx - 133/150, 89%, full - 2026-08-21
      LOG

      expect(seed.best).to eq("Qwen3.8-27B-UD-IQ4_XS" => "llama.cpp")
    end

    # The whole point of the seed: two engines ran the same weights and one
    # scored better. Picking the wrong one silently re-runs the sweep on the
    # engine already known to lose.
    it "keeps the highest-scoring engine when one model ran on several" do
      seed = seed_for(<<~LOG)
        ### Qwen3.8-27B - UD-IQ4_XS - ik_llama.cpp - 120,064 ctx, n_cpu_moe=0 - 70/85, 82%, default-5 - 2026-08-21
        ### Qwen3.8-27B - UD-IQ4_XS - llama.cpp - 110,080 ctx - 72/85, 85%, default-5 - 2026-08-21
      LOG

      expect(seed.best).to eq("Qwen3.8-27B-UD-IQ4_XS" => "llama.cpp")
    end

    # A 91% over 45 cases and an 87% over 150 are not the same evidence, and
    # the smaller run is the one that gets lucky.
    it "prefers the run with more cases when two percentages tie" do
      seed = seed_for(<<~LOG)
        ### Model-A - Q4_K_M - ik_llama.cpp - 60,160 ctx - 39/45, 87%, fastest-3 - 2026-08-21
        ### Model-A - Q4_K_M - llama.cpp - 60,160 ctx - 130/150, 87%, high-8 - 2026-08-25
      LOG

      expect(seed.best).to eq("Model-A-Q4_K_M" => "llama.cpp")
    end

    it "keeps models apart when they differ only by quant" do
      seed = seed_for(<<~LOG)
        ### Qwen3.8-27B - UD-IQ4_XS - llama.cpp - 110,080 ctx - 133/150, 89%, full - 2026-08-21
        ### Qwen3.8-27B - UD-Q4_K_XL - ik_llama.cpp - 80,128 ctx, n_cpu_moe=0 - 40/45, 89%, fastest-3 - 2026-08-21
      LOG

      expect(seed.best).to eq("Qwen3.8-27B-UD-IQ4_XS" => "llama.cpp",
                              "Qwen3.8-27B-UD-Q4_K_XL" => "ik_llama.cpp")
    end

    it "ignores prose, tables and headers that are not results blocks" do
      seed = seed_for(<<~LOG)
        ## Local-only quality benches

        ### Qwen3.8-27B - UD-IQ4_XS - llama.cpp - 110,080 ctx - 133/150, 89%, full - 2026-08-21
          (runner=1d27ae1 · sandbox images: bugfind=78abbbe9bbb1)

        | Pack        | Score | %   |
        |-------------|-------|-----|
        | toolcall-15 | 13/15 | 87% |
      LOG

      expect(seed.best).to eq("Qwen3.8-27B-UD-IQ4_XS" => "llama.cpp")
    end

    it "yields nothing rather than raising when the log is missing" do
      expect(described_class.new(Pathname.new(@dir) / "gone.md").best).to eq({})
    end
  end

  describe "#apply" do
    def model_double(stem, memory)
      instance_double(Mimic::Model, path: Pathname.new("/models/#{stem}.gguf"), memory: memory)
    end

    it "remembers the seeded engine for every model the log names" do
      memory = instance_double(Mimic::Model::Memory)
      seed = seed_for("### Model-A - Q4_K_M - ik_llama.cpp - 60,160 ctx - 39/45, 87%, fastest-3 - 2026-08-21\n")

      expect(memory).to receive(:remember_engine).with("ik_llama.cpp")

      expect(seed.apply([model_double("Model-A-Q4_K_M", memory)])).to eq(1)
    end

    # A model with no logged run keeps whatever verdict it already had --
    # the seed adds evidence, it does not clear the store.
    it "leaves a model the log does not name untouched" do
      memory = instance_double(Mimic::Model::Memory)
      seed = seed_for("### Model-A - Q4_K_M - ik_llama.cpp - 60,160 ctx - 39/45, 87%, fastest-3 - 2026-08-21\n")

      expect(memory).not_to receive(:remember_engine)

      expect(seed.apply([model_double("Other-Model-Q8_0", memory)])).to eq(0)
    end
  end
end
