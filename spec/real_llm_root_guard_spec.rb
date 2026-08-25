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

  # A deleted live pid file is how `llm status` lost the running server's pid:
  # ik's retry loop calls cleanup_failed, which unlinks whatever pid_file
  # resolves to, and the guard only watched writes.
  it "refuses to unlink a file under the real llm root" do
    expect { (real_root / "config.yaml").unlink }.to raise_error(RealLlmRootGuard::Violation, /config\.yaml/)
  end

  # PID_DIR is /tmp/llm, outside the llm root, and holds the pid files the
  # running servers are tracked by. The target is a name no server uses: an
  # example naming the live llama-server.pid deletes it on any run where the
  # guard is not yet in place.
  it "refuses to unlink a pid file" do
    expect { (Mimic::Paths::PID_DIR / "never-a-real-server.pid").unlink }
      .to raise_error(RealLlmRootGuard::Violation, /never-a-real-server\.pid/)
  end

  it "refuses a write under the pid dir" do
    expect { (Mimic::Paths::PID_DIR / "escaped.pid").write("1") }.to raise_error(RealLlmRootGuard::Violation)
  end

  # Client configs live under other tools' trees, and a spec that forgets one
  # stub_const rewrites the user's real agent config -- a mutation run against
  # Client::Goose wrote ~/.config/goose/custom_providers/llamacpp.json that
  # way. As above, the target names a file no real client uses.
  it "refuses a write under a client config dir" do
    expect { (Pathname.new(Dir.home) / ".config/goose/never-a-real-client.json").write("{}") }
      .to raise_error(RealLlmRootGuard::Violation, /never-a-real-client\.json/)
  end

  it "refuses to create a directory under one" do
    expect { (Pathname.new(Dir.home) / ".pi/agent/never-a-real-dir").mkpath }
      .to raise_error(RealLlmRootGuard::Violation)
  end

  # ~/.mimic is the agent side's state tree -- the isolated Claude config dir,
  # the PATH shim and the opt-in mcp-servers.json all live there, and a spec
  # that forgets to stub CLAUDE_CONFIG_DIR reseeds the user's real one.
  it "refuses a write under the agent state dir" do
    expect { (Mimic::Paths::STATE_DIR / "never-a-real-state.json").write("{}") }
      .to raise_error(RealLlmRootGuard::Violation, /never-a-real-state\.json/)
  end

  it "refuses to create a directory under it" do
    expect { (Mimic::Paths::STATE_DIR / "never-a-real-dir/nested").mkpath }
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
