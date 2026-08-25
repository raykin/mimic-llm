require_relative "../../lib/mimic"

RSpec.describe Mimic::LlmConfig::Sampling do
  def sampling(**overrides)
    described_class.new({ "temperature" => 0.6, "top_p" => 0.95, "top_k" => 20, "min_p" => 0.0,
                          "presence_penalty" => 1.5, "repeat_penalty" => 1.0 }.merge(overrides.transform_keys(&:to_s)))
  end

  # Both engines write these in the same order with the same spellings; the
  # order is what keeps the rendered preset stable.
  it "maps config keys to engine flag names, in a fixed order" do
    expect(sampling.to_h.keys).to eq(["temp", "top-p", "top-k", "min-p", "presence-penalty", "repeat-penalty"])
  end

  it "carries the configured values through" do
    expect(sampling(temperature: 0.1, top_k: 40).to_h)
      .to include("temp" => 0.1, "top-k" => 40, "top-p" => 0.95)
  end

  it "renders CLI arguments as flag/value pairs of strings" do
    expect(sampling.to_args.first(4)).to eq(["--temp", "0.6", "--top-p", "0.95"])
    expect(sampling.to_args.size).to eq(described_class::KEYS.size * 2)
    expect(sampling.to_args).to all(be_a(String))
  end

  it "passes a missing value through as an empty string rather than raising" do
    expect(described_class.new({}).to_args).to include("--temp", "")
  end

  describe "DEFAULTS" do
    it "names every sampler key" do
      expect(described_class::DEFAULTS.keys).to eq(described_class::KEYS)
    end

    # These are llama-server's own defaults, so "no override" and "no flag"
    # describe the same server behaviour.
    it "holds the engine's own defaults" do
      expect(described_class::DEFAULTS).to eq(
        "temperature" => 0.8, "top_p" => 0.95, "top_k" => 40,
        "min_p" => 0.05, "presence_penalty" => 0.0, "repeat_penalty" => 1.0,
      )
    end
  end

  describe ".resolve" do
    it "returns the defaults when the header suggests nothing" do
      expect(described_class.resolve({})).to eq(described_class::DEFAULTS)
    end

    it "lets the header's published suggestion override the default" do
      resolved = described_class.resolve("general.sampling.temp" => 1.0, "general.sampling.top_k" => 64)
      expect(resolved).to include("temperature" => 1.0, "top_k" => 64)
    end

    it "leaves the keys no header carries at their default" do
      resolved = described_class.resolve("general.sampling.temp" => 1.0)
      expect(resolved).to include("min_p" => 0.05, "presence_penalty" => 0.0, "repeat_penalty" => 1.0)
    end

    # GGUF stores these as float32, so 0.95 reads back as 0.949999988079071.
    it "rounds a float32 suggestion back to what the publisher wrote" do
      expect(described_class.resolve("general.sampling.top_p" => 0.949999988079071))
        .to include("top_p" => 0.95)
    end

    it "ignores a header key that is not a sampler suggestion" do
      expect(described_class.resolve("general.name" => "Qwen3.8-27B")).to eq(described_class::DEFAULTS)
    end
  end
end
