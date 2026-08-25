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

    it "returns a Llama instance for the current Prism fork" do
      expect(described_class.for(settings_for("prism-v7-llama.cpp"))).to be_a(Mimic::Engine::Llama)
    end
  end

  describe ".names" do
    it "offers the prism fork in a checkout" do
      allow(Mimic::Paths).to receive(:dev_build?).and_return(true)

      expect(described_class.names).to include("prism-v7-llama.cpp")
    end

    it "offers the current Prism fork in an installed gem" do
      allow(Mimic::Paths).to receive(:dev_build?).and_return(false)

      expect(described_class.names).to eq(["llama.cpp", "ik_llama.cpp", "prism-v7-llama.cpp"])
    end

    it "knows the current Prism branch" do
      allow(Mimic::Paths).to receive(:dev_build?).and_return(false)

      expect(described_class.known?("prism-llama.cpp")).to be(false)
      expect(described_class.branch("prism-v7-llama.cpp")).to eq("prism")
    end
  end

  describe ".binaries" do
    it "lets llama.cpp prefer a llama-server on PATH" do
      allow(Mimic::Util::Probes).to receive(:which).with("llama-server").and_return("/usr/bin/llama-server")

      expect(described_class.binaries("llama.cpp").first).to eq("/usr/bin/llama-server")
    end

    it "never offers PATH to the prism fork, whose weights no other build reads" do
      allow(Mimic::Util::Probes).to receive(:which).with("llama-server").and_return("/usr/bin/llama-server")

      expect(described_class.binaries("prism-v7-llama.cpp").map(&:to_s)).to all(include("prism-v7-llama.cpp"))
    end
  end
end
