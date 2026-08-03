require_relative "../../lib/mimic"

RSpec.describe Mimic::Services::Engine do
  def settings_for(engine)
    Mimic::LlmConfig::Settings.new("llama" => { "engine" => engine }.compact)
  end

  describe ".for" do
    it "returns a Llama instance for the default (llama.cpp) engine" do
      expect(described_class.for(settings_for("llama.cpp"))).to be_a(Mimic::Services::Llama)
    end

    it "returns a Llama instance when no engine is configured" do
      expect(described_class.for(settings_for(nil))).to be_a(Mimic::Services::Llama)
    end

    it "returns an IkLlama instance for the ik_llama.cpp engine" do
      expect(described_class.for(settings_for("ik_llama.cpp"))).to be_a(Mimic::Services::IkLlama)
    end
  end
end
