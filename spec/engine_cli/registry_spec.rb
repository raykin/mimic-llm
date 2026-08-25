require_relative "../../lib/mimic"

RSpec.describe Mimic::EngineCli::Registry do
  def settings_for(engine)
    Mimic::LlmConfig::Settings.new("llama" => { "engine" => engine }.compact)
  end

  describe ".for" do
    it "returns a Llama instance for the default (llama.cpp) engine" do
      expect(described_class.for(settings_for("llama.cpp"))).to be_a(Mimic::Engine::Llama)
    end

    it "returns a Llama instance when no engine is configured" do
      expect(described_class.for(settings_for(nil))).to be_a(Mimic::Engine::Llama)
    end

    it "returns an IkLlama instance for the ik_llama.cpp engine" do
      expect(described_class.for(settings_for("ik_llama.cpp"))).to be_a(Mimic::Engine::IkLlama)
    end

    it "returns a Llama instance for the prism-llama.cpp fork" do
      expect(described_class.for(settings_for("prism-llama.cpp"))).to be_a(Mimic::Engine::Llama)
    end
  end

  describe ".binaries" do
    it "lets llama.cpp prefer a llama-server on PATH" do
      allow(Mimic::Util::Probes).to receive(:which).with("llama-server").and_return("/usr/bin/llama-server")

      expect(described_class.binaries("llama.cpp").first).to eq("/usr/bin/llama-server")
    end

    it "never offers PATH to the prism fork, whose weights no other build reads" do
      allow(Mimic::Util::Probes).to receive(:which).with("llama-server").and_return("/usr/bin/llama-server")

      expect(described_class.binaries("prism-llama.cpp").map(&:to_s)).to all(include("prism-llama.cpp"))
    end
  end
end
