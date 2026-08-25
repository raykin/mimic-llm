require "pathname"
require "mimic/engine_cli"

RSpec.describe Mimic::EngineCli::Update do
  subject(:updater) { described_class.new }

  def status(name, behind:, subject_line: "some commit")
    {
      name: name,
      repo: Pathname.new("/tmp/#{name}"),
      branch: "master",
      local: "aaaaaaaaa",
      remote: "bbbbbbbbb",
      behind: behind,
      dirty: false,
      subject: subject_line,
    }
  end

  before do
    allow(Mimic::EngineCli::Source).to receive(:record_last_good)
    allow(Mimic::EngineCli::Source).to receive(:status).with("llama.cpp").and_return(status("llama.cpp", behind: 0))
    allow(Mimic::EngineCli::Source).to receive(:status).with("ik_llama.cpp")
      .and_return(status("ik_llama.cpp", behind: 28, subject_line: "Compiler warning"))
    allow(Mimic::EngineCli::Source).to receive(:status).with("prism-llama.cpp").and_return(nil)
    allow(Mimic::EngineCli::Source).to receive(:build_command).with("ik_llama.cpp").and_return("cd /tmp/ik_llama.cpp && cmake --build build")
    allow(updater).to receive(:system).and_return(true)
  end

  it "names the engines needing a rebuild rather than printing a bare banner" do
    expect { updater.run }.to output(/rebuilding: ik_llama\.cpp/).to_stdout
  end

  it "does not name an up-to-date engine in the rebuild header" do
    expect { updater.run }.not_to output(/rebuilding:.*llama\.cpp,/).to_stdout
  end

  it "appends the newest upstream commit subject to the remote sha" do
    expect { updater.run }.to output(/bbbbbbbbb \(Compiler warning\)/).to_stdout
  end

  it "separates the status list from the build section with a divider" do
    expect { updater.run }.to output(/\n-{10,}\nrebuilding:/).to_stdout
  end

  it "runs the rebuild command for each pending engine, once each" do
    updater.run
    expect(updater).to have_received(:system).with("cd /tmp/ik_llama.cpp && cmake --build build").once
  end

  it "reports which engines failed to build" do
    allow(updater).to receive(:system).and_return(false)
    expect { updater.run }.to output(/failed: ik_llama\.cpp/).to_stdout
  end

  it "reports success when every rebuild succeeds" do
    expect { updater.run }.to output(/-{10,}\nRebuild complete\./).to_stdout
  end

  describe "#rollback" do
    before do
      allow(Mimic::EngineCli::Source).to receive(:last_good).with("ik_llama.cpp").and_return("aaaaaaaaa")
      allow(Mimic::EngineCli::Source).to receive(:build_command).with("ik_llama.cpp", ref: "aaaaaaaaa")
        .and_return("cd /tmp/ik_llama.cpp && git checkout aaaaaaaaa && cmake --build build")
    end

    it "errors when no last-good commit is recorded" do
      allow(Mimic::EngineCli::Source).to receive(:last_good).with("llama.cpp").and_return(nil)
      result = updater.rollback("llama.cpp")
      expect(result.ok?).to be false
    end

    it "runs the rollback build command and returns nil on success" do
      expect(updater.rollback("ik_llama.cpp")).to be_nil
      expect(updater).to have_received(:system).with("cd /tmp/ik_llama.cpp && git checkout aaaaaaaaa && cmake --build build")
    end

    it "returns a failing Result when the rollback build fails" do
      allow(updater).to receive(:system).and_return(false)
      result = updater.rollback("ik_llama.cpp")
      expect(result.ok?).to be false
    end
  end
end
