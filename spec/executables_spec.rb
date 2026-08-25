require "spec_helper"

RSpec.describe "declared executables" do
  let(:root) { Pathname.new(__dir__).parent }
  let(:spec) { Gem::Specification.load((root / "mimic-llm.gemspec").to_s) }

  it "ships a file in exe/ for every declared executable" do
    missing = spec.executables.reject { |name| (root / "exe" / name).file? }
    expect(missing).to be_empty
  end

  it "offers lllm as a name that survives an llm already on PATH" do
    expect(spec.executables).to include("lllm")
    expect((root / "exe/lllm").read).to eq((root / "exe/llm").read)
  end
end
