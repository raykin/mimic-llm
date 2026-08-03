require_relative "../lib/mimic/result"

RSpec.describe Mimic::Result do
  describe ".ok" do
    it "is ok? true and carries the message" do
      result = described_class.ok("llama-server ready")
      expect(result.ok?).to be true
      expect(result.message).to eq("llama-server ready")
    end
  end

  describe ".error" do
    it "is ok? false and carries the message" do
      result = described_class.error("llama-server binary not found")
      expect(result.ok?).to be false
      expect(result.message).to eq("llama-server binary not found")
    end
  end
end
