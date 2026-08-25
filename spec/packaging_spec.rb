require "spec_helper"

RSpec.describe "gem package contents" do
  let(:root) { Pathname.new(__dir__).parent }
  let(:files) { Gem::Specification.load((root / "mimic-llm.gemspec").to_s).files }

  it "ships the runtime data files lib/ depends on, not only its .rb files" do
    expect(files).to include("lib/mimic/agent/codex_fallback_prompt.md")
  end

  it "ships the licence and the attribution for the vendored prompt" do
    expect(files).to include("LICENSE", "NOTICE", "README.md")
  end
end
