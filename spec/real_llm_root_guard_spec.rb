require_relative "../lib/mimic"
require "tmpdir"

# The guard the whole suite runs under. Per-spec stub_const isolation is
# opt-in, so a store added to an engine's post-success path writes the user's
# real ~/.llm until someone notices by eye -- model-sampling.json collected
# the fixture keys /m.gguf and /models/foo-Q4_K_M.gguf that way.
RSpec.describe RealLlmRootGuard do
  def real_root = Pathname.new(Dir.home) / ".llm"

  it "refuses a write under the user's real llm root" do
    expect { (real_root / "escaped.json").write("{}") }
      .to raise_error(RealLlmRootGuard::Violation, /escaped\.json/)
  end

  it "refuses to create a directory under it" do
    expect { (real_root / "escaped/nested").mkpath }.to raise_error(RealLlmRootGuard::Violation)
  end

  it "refuses a write opened through open" do
    expect { (real_root / "escaped.json").open("w") { |f| f.write("{}") } }
      .to raise_error(RealLlmRootGuard::Violation)
  end

  # ENOENT rather than Violation is the proof: the read reached the
  # filesystem instead of being intercepted.
  it "leaves reads under the real root alone" do
    expect { real_root.exist? }.not_to raise_error
    expect { (real_root / "absent-by-design.json").read }.to raise_error(Errno::ENOENT)
  end

  it "leaves writes outside the real root alone" do
    Dir.mktmpdir do |dir|
      target = Pathname.new(dir) / "fine.json"
      target.write("{}")

      expect(target.read).to eq("{}")
    end
  end
end
