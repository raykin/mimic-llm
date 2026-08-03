require_relative "../lib/mimic"
require_relative "../lib/mimic/llm_configure"

RSpec.describe Mimic::LlmConfigure do
  let(:cfg) { { "model" => { "temperature" => 0.6 }, "llama" => { "port" => 1 } } }

  describe ".set" do
    # Ruby's Kernel#Integer honours radix prefixes, Python's int() does not:
    # a port typed as "010" became 8 here and 10 there.
    it "reads a leading-zero integer as decimal, not octal" do
      described_class.set(cfg, "llama.port", "010")
      expect(described_class.get(cfg, "llama.port")).to eq(10)
    end

    it "rejects a hex literal rather than accepting base 16" do
      expect { described_class.set(cfg, "llama.port", "0x10") }.to raise_error(ArgumentError)
    end

    it "still accepts a plain integer with surrounding space" do
      described_class.set(cfg, "llama.port", " 8081 ")
      expect(described_class.get(cfg, "llama.port")).to eq(8081)
    end

    # Deliberate divergence: float("nan") gives Python a NaN temperature that
    # then reaches the engine preset. Kernel#Float refuses, and `llm config`
    # keeps the previous value.
    it "rejects a non-finite float" do
      expect { described_class.set(cfg, "model.temperature", "nan") }.to raise_error(ArgumentError)
    end
  end
end
