require_relative "../lib/mimic"
require_relative "../lib/mimic/engine_builder"
require "tmpdir"
require "fileutils"

RSpec.describe Mimic::EngineBuilder do
  def builder(cfg = { "model" => {}, "llama" => {} })
    described_class.new(Mimic::LlmConfig::Settings.new(cfg), cli_name: "llm",
                                                             prompt: instance_double(TTY::Prompt), pastel: Pastel.new)
  end

  describe "#build" do
    def stub_build(instance, dir, engine)
      seen = []
      allow(instance).to receive(:system) do |*args|
        seen << args
        if args.include?("--target")
          binary = Pathname.new(dir) / engine / "build" / "bin" / "llama-server"
          binary.dirname.mkpath
          FileUtils.touch(binary)
        end
        true
      end
      seen
    end

    # Regression: build must source under the same underscore directory name
    # Services::Engines::ENGINES and IkLlama::KNOWN_BINARIES key off
    # ("ik_llama.cpp"), all rooted at LlmConfig::LLM_CONFIG_DIR (~/.llm). A
    # binary built under a different name is never found by engine
    # status/update or by find_binary.
    it "builds under the same directory name IkLlama/Engines expect for ik_llama.cpp" do
      Dir.mktmpdir do |dir|
        stub_const("Mimic::LlmConfig::LLM_CONFIG_DIR", Pathname.new(dir))
        allow(Mimic::Probes).to receive(:which).and_return("/usr/bin/tool")
        instance = builder
        stub_build(instance, dir, "ik_llama.cpp")

        src = instance.build("ik_llama.cpp")
        built_dir = Pathname.new(src).dirname.dirname.dirname

        expect(built_dir).to eq(Pathname.new(dir) / "ik_llama.cpp")
      end
    end

    # gh-proxy takes the whole upstream URL after its own host. Dropping the
    # scheme yields $GH_MIRROR/github.com/... , which the mirror 404s.
    it "keeps the scheme in the mirrored clone URL" do
      Dir.mktmpdir do |dir|
        stub_const("Mimic::LlmConfig::LLM_CONFIG_DIR", Pathname.new(dir))
        allow(Mimic::Probes).to receive(:which).and_return("/usr/bin/tool")
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with("GH_MIRROR", "").and_return("https://gh-proxy.com")
        instance = builder
        seen = stub_build(instance, dir, "llama.cpp")

        instance.build("llama.cpp")

        expect(seen.find { |a| a.include?("clone") })
          .to include("https://gh-proxy.com/https://github.com/ggml-org/llama.cpp.git")
      end
    end

    it "caps parallel build jobs by RAM, not just by CPU count" do
      Dir.mktmpdir do |dir|
        stub_const("Mimic::LlmConfig::LLM_CONFIG_DIR", Pathname.new(dir))
        (Pathname.new(dir) / "llama.cpp/.git").mkpath
        allow(Mimic::Probes).to receive(:which).and_return("/usr/bin/tool")
        allow(File).to receive(:readlines).and_call_original
        allow(File).to receive(:readlines).with("/proc/meminfo").and_return(["MemTotal:       8000000 kB\n"])
        allow(Etc).to receive(:nprocessors).and_return(20)
        instance = builder
        seen = stub_build(instance, dir, "llama.cpp")

        instance.build("llama.cpp")

        build = seen.find { |a| a.include?("--target") }
        expect(build.grep(/\A-j\d/)).to eq(["-j2"])
      end
    end

    it "exits when a build tool is missing" do
      allow(Mimic::Probes).to receive(:which).and_return(nil)
      expect { builder.build("llama.cpp") }.to output(/'git' is required/).to_stdout.and raise_error(SystemExit)
    end
  end
end
