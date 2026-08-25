require_relative "../lib/mimic"
require_relative "../lib/mimic/cli"

RSpec.describe Mimic::Cli do
  describe "MENU" do
    it "pairs each label with a bound Method object" do
      described_class::MENU.each do |_label, handler|
        expect(handler).to be_a(Method)
      end
    end
  end

  describe ".menu" do
    it "dispatches to the handler for the picked label" do
      allow(Mimic::LlmConfig).to receive(:exists?).and_return(true)
      allow(Mimic::LlmConfig).to receive(:load).and_return({})
      allow(Mimic::Health).to receive(:run).and_return(true)
      verify_label = described_class::MENU.find { |_label, handler| handler.name == :cmd_verify }.first
      prompt = instance_double(Mimic::Ui::Prompt, select: verify_label)
      allow(Mimic::Ui::Prompt).to receive(:new).and_return(prompt)

      described_class.menu

      expect(Mimic::Health).to have_received(:run)
    end

    it "returns nil instead of raising when the prompt is interrupted" do
      prompt = instance_double(Mimic::Ui::Prompt)
      allow(Mimic::Ui::Prompt).to receive(:new).and_return(prompt)
      allow(prompt).to receive(:select).and_raise(Interrupt)

      expect(described_class.menu).to be_nil
    end
  end
end
