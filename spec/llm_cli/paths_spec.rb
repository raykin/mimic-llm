require_relative "../../lib/mimic"
require "tmpdir"
require "fileutils"
require "stringio"

RSpec.describe Mimic::LlmCli::Paths do
  let(:cli) { described_class.new }
  let(:saved) { [] }

  def run(&block)
    out = StringIO.new
    orig = $stdout
    $stdout = out
    block.call
    out.string
  ensure
    $stdout = orig
  end

  def configure(paths)
    settings = Mimic::LlmConfig::Settings.new("model" => { "search_paths" => paths })
    allow(settings).to receive(:save) { saved << Marshal.load(Marshal.dump(settings.to_h)) }
    allow(Mimic::LlmConfig).to receive(:load).and_return(settings)
  end

  before do
    stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [Pathname.new("/opt/builtin")])
    configure([])
  end

  describe "#add" do
    it "saves a real directory and reports it" do
      Dir.mktmpdir do |dir|
        text = run { cli.add(dir) }
        expect(saved.last["model"]["search_paths"]).to eq([dir])
        expect(text).to include("Added", dir)
      end
    end

    it "refuses a path that is not a directory without saving" do
      expect { run { cli.add("/definitely/not/here") } }.to raise_error(SystemExit)
      expect(saved).to be_empty
    end

    it "refuses a file without saving" do
      Dir.mktmpdir do |dir|
        file = File.join(dir, "model.gguf")
        FileUtils.touch(file)
        expect { run { cli.add(file) } }.to raise_error(SystemExit)
        expect(saved).to be_empty
      end
    end

    it "reports a builtin dir without saving" do
      allow(Pathname).to receive(:new).and_call_original
      text = run { cli.add("/opt/builtin") }
      expect(text).to include("already searched")
      expect(saved).to be_empty
    end

    it "reports a duplicate without saving" do
      Dir.mktmpdir do |dir|
        configure([dir])
        text = run { cli.add(dir) }
        expect(text).to include("already")
        expect(saved).to be_empty
      end
    end
  end

  describe "#rm" do
    it "removes a configured dir and saves" do
      configure(["/mnt/models"])
      text = run { cli.rm("/mnt/models") }
      expect(saved.last["model"]["search_paths"]).to eq([])
      expect(text).to include("Removed")
    end

    it "removes a dir that no longer exists on disk" do
      configure(["/gone"])
      run { cli.rm("/gone") }
      expect(saved.last["model"]["search_paths"]).to eq([])
    end

    it "refuses to remove a builtin" do
      expect { run { cli.rm("/opt/builtin") } }.to raise_error(SystemExit)
      expect(saved).to be_empty
    end

    it "exits non-zero for a dir that was never added" do
      expect { run { cli.rm("/mnt/nope") } }.to raise_error(SystemExit)
      expect(saved).to be_empty
    end
  end

  describe "#list" do
    it "marks builtin dirs and configured dirs differently" do
      configure(["/mnt/models"])
      text = run { cli.list }
      expect(text).to include("/opt/builtin", "builtin", "/mnt/models")
    end

    it "does not save anything" do
      run { cli.list }
      expect(saved).to be_empty
    end
  end
end
