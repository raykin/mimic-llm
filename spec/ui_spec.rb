require_relative "../lib/mimic/ui"

RSpec.describe Mimic::Ui::Prompt do
  # cli-ui hardcodes the arrow/return glyphs into the instruction line it
  # prints with the question. The return one renders as a box in this
  # terminal, so it is spelled out instead.
  describe "the select instructions" do
    it "spells out the keys that select instead of drawing one" do
      expect { CLI::UI::Prompt.send(:puts_question, "Engine: (Choose with ↑ ↓ ⏎)") }
        .to output(%r{Choose with ↑ ↓ Enter/Space}).to_stdout
    end

    it "leaves a question without the glyph alone" do
      expect { CLI::UI::Prompt.send(:puts_question, "Engine:") }.to output(/Engine:/).to_stdout
    end
  end

  describe "#ask" do
    # cli-ui reads the answer through Reline, which opens /dev/tty rather than
    # $stdin -- swapping $stdin left the whole suite waiting on a keypress, so
    # the read itself is stubbed and only cli-ui's empty-answer handling runs.
    before { allow(CLI::UI::Prompt).to receive(:readline).and_return("") }

    # Reline reads the tty, not $stdin, so an empty answer is the only one
    # this can drive headlessly -- and it is the one that was broken.
    #
    # cli-ui raises ArgumentError on `default:` together with allow_empty:
    # false, which is every wizard ask that offers a current value --
    # `llm embed setup` died at its port question.
    it "returns the default when the answer is empty" do
      answer = nil
      expect { answer = described_class.new.ask("Port:", default: 8081, convert: :int) }.to output(/Port:/).to_stdout

      expect(answer).to eq(8081)
    end
  end
end
