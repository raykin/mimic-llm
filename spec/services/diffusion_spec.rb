require_relative "../../lib/mimic"
require "tmpdir"
require "fileutils"

RSpec.describe Mimic::Services::Diffusion do
  describe ".find_binary" do
    it "returns the configured binary when present on disk" do
      Dir.mktmpdir do |dir|
        binary = Pathname.new(dir) / "llama-diffusion-cli"
        FileUtils.touch(binary)
        cfg = { "diffusion" => { "binary" => binary.to_s } }
        expect(described_class.find_binary(cfg)).to eq(binary.to_s)
      end
    end

    it "falls back to a known binary path when nothing is configured" do
      cfg = {}
      known = described_class::KNOWN_BINARIES.first
      allow(known).to receive(:file?).and_return(true)
      expect(described_class.find_binary(cfg)).to eq(known.to_s)
    end

    it "falls back to PATH when no known binary exists" do
      cfg = {}
      allow(described_class::KNOWN_BINARIES.first).to receive(:file?).and_return(false)
      allow(Mimic::Probes).to receive(:which).with("llama-diffusion-cli").and_return("/usr/local/bin/llama-diffusion-cli")
      expect(described_class.find_binary(cfg)).to eq("/usr/local/bin/llama-diffusion-cli")
    end
  end

  describe ".build" do
    it "clones the PR ref as a local branch, builds llama-diffusion-cli, and returns its path" do
      Dir.mktmpdir do |dir|
        repo = Pathname.new(dir) / "llama.cpp-diffusion"
        stub_const("Mimic::Services::Diffusion::REPO", repo)
        allow(Mimic::Probes).to receive(:which).and_return("/usr/bin/tool")

        seen_args = []
        allow(described_class).to receive(:system) do |*args|
          seen_args << args
          if args.include?("--target")
            binary = repo / "build" / "bin" / "llama-diffusion-cli"
            binary.dirname.mkpath
            FileUtils.touch(binary)
          end
          true
        end

        result = described_class.build(Pastel.new)

        expect(result).to eq((repo / "build/bin/llama-diffusion-cli").to_s)
        expect(seen_args.any? { |a| a.any? { |x| x.to_s.include?(described_class::PR_REF) } }).to be true
        expect(seen_args.any? { |a| a.include?("llama-diffusion-cli") && a.include?("--target") }).to be true
      end
    end

    # gh-proxy takes the whole upstream URL after its own host; dropping the
    # scheme yields $GH_MIRROR/github.com/... , which the mirror 404s.
    it "keeps the scheme in the mirrored clone URL" do
      Dir.mktmpdir do |dir|
        repo = Pathname.new(dir) / "llama.cpp-diffusion"
        stub_const("Mimic::Services::Diffusion::REPO", repo)
        allow(Mimic::Probes).to receive(:which).and_return("/usr/bin/tool")
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with("GH_MIRROR", "").and_return("https://gh-proxy.com")

        seen_args = []
        allow(described_class).to receive(:system) do |*args|
          seen_args << args
          if args.include?("--target")
            binary = repo / "build" / "bin" / "llama-diffusion-cli"
            binary.dirname.mkpath
            FileUtils.touch(binary)
          end
          true
        end

        described_class.build(Pastel.new)

        expect(seen_args.find { |a| a.include?("clone") })
          .to include("https://gh-proxy.com/https://github.com/ggml-org/llama.cpp.git")
      end
    end

    it "caps parallel build jobs by RAM, not just by CPU count" do
      Dir.mktmpdir do |dir|
        repo = Pathname.new(dir) / "llama.cpp-diffusion"
        (repo / ".git").mkpath
        stub_const("Mimic::Services::Diffusion::REPO", repo)
        allow(Mimic::Probes).to receive(:which).and_return("/usr/bin/tool")
        allow(File).to receive(:readlines).and_call_original
        allow(File).to receive(:readlines).with("/proc/meminfo").and_return(["MemTotal:       8000000 kB\n"])
        allow(Etc).to receive(:nprocessors).and_return(20)

        seen_args = []
        allow(described_class).to receive(:system) do |*args|
          seen_args << args
          if args.include?("--target")
            binary = repo / "build" / "bin" / "llama-diffusion-cli"
            binary.dirname.mkpath
            FileUtils.touch(binary)
          end
          true
        end

        described_class.build(Pastel.new)

        build = seen_args.find { |a| a.include?("--target") }
        expect(build[build.index("-j") + 1]).to eq("2")
      end
    end
  end

  describe ".build_command" do
    it "builds a one-shot generate command with the given context size and block count" do
      expect(described_class.build_command("/bin/llama-diffusion-cli", "/m.gguf", "hello", ctx: 2048, blocks: 4))
        .to eq(["/bin/llama-diffusion-cli", "-m", "/m.gguf", "-p", "hello", "-ngl", "999", "-c", "2048", "--diffusion-blocks", "4"])
    end

    it "defaults to enough blocks that a 256-token canvas doesn't truncate mid-answer" do
      cmd = described_class.build_command("/bin/llama-diffusion-cli", "/m.gguf", "hello")
      expect(cmd).to include("--diffusion-blocks")
      expect(cmd[cmd.index("--diffusion-blocks") + 1].to_i).to be > 1
    end
  end
end
