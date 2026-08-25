require_relative "../lib/mimic/ui"
require "stringio"

RSpec.describe Mimic::Ui::Prompt do
  # cli-ui reads the answer off $stdin itself, so the only way to pin what it
  # does with our arguments is to hand it a real one.
  def answering(text)
    read, write = IO.pipe
    write.write(text)
    write.close
    previous = $stdin
    $stdin = read
    yield
  ensure
    $stdin = previous
    read.close
  end

  describe "#ask" do
    # Reline reads the tty, not $stdin, so an empty answer is the only one
    # this can drive headlessly -- and it is the one that was broken.
    #
    # cli-ui raises ArgumentError on `default:` together with allow_empty:
    # false, which is every wizard ask that offers a current value --
    # `llm embed setup` died at its port question.
    it "returns the default when the answer is empty" do
      answer = nil
      expect { answer = answering("\n") { described_class.new.ask("Port:", default: 8081, convert: :int) } }
        .to output(/Port:/).to_stdout

      expect(answer).to eq(8081)
    end
  end
end
