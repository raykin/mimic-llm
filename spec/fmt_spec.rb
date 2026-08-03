require_relative "../lib/mimic"

RSpec.describe Mimic::Fmt do
  describe ".commas" do
    it "groups thousands" do
      expect(described_class.commas(180_000)).to eq("180,000")
    end

    it "leaves short numbers alone" do
      expect(described_class.commas(512)).to eq("512")
    end
  end

  describe ".human_size" do
    it "formats using decimal GB (1000^3), not binary GiB" do
      expect(described_class.human_size(17_399_835_584)).to eq("17.4 GB")
    end
  end
end
