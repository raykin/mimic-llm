require_relative "../lib/mimic"

RSpec.describe Mimic::Wizard do
  describe ".ensure_hermes" do
    it "returns the existing binary without prompting" do
      allow(Mimic::Services::Hermes).to receive(:find_binary).and_return("/opt/hermes")
      prompt = instance_double(TTY::Prompt)

      expect(described_class.ensure_hermes(prompt)).to eq("/opt/hermes")
    end

    it "returns nil when the user declines the venv install" do
      allow(Mimic::Services::Hermes).to receive(:find_binary).and_return(nil)
      prompt = instance_double(TTY::Prompt)
      allow(prompt).to receive(:yes?).and_yield(double(default: nil)).and_return(false)

      expect(described_class.ensure_hermes(prompt)).to be_nil
    end
  end
end
