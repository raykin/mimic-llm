require_relative "../lib/mimic"
require_relative "../lib/mimic/agent"

RSpec.describe Mimic::Agent do
  describe ".version_at_least?" do
    it "is true when strictly greater" do
      expect(described_class.version_at_least?([2, 2, 0], [2, 1, 98])).to be true
    end

    it "is true when exactly equal" do
      expect(described_class.version_at_least?([2, 1, 98], [2, 1, 98])).to be true
    end

    it "is false when lower" do
      expect(described_class.version_at_least?([2, 1, 0], [2, 1, 98])).to be false
    end
  end

  describe ".spawn_and_wait" do
    it "exits non-zero with a message when the command isn't on PATH" do
      expect do
        expect { described_class.spawn_and_wait(["definitely-not-a-real-binary-xyz"], {}) }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end.to output(/not found on PATH/).to_stderr
    end
  end
end
