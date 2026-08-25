require_relative "../../lib/mimic"
require_relative "../../lib/mimic/engine_cli"
require "tmpdir"
require "fileutils"

RSpec.describe Mimic::EngineCli::Builder do
  def builder(cfg = { "model" => {}, "llama" => {} })
    described_class.new(Mimic::LlmConfig::Settings.new(cfg), cli_name: "llm",
                                                             prompt: instance_double(Mimic::Ui::Prompt))
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
    # Registry keys off ("ik_llama.cpp"), rooted at Paths::LLM_ROOT (~/.llm).
    # A binary built under a different name is never found by engine
    # status/update or by find_binary.
    it "builds under the same directory name the registry resolves for ik_llama.cpp" do
      Dir.mktmpdir do |dir|
        stub_const("Mimic::Paths::LLM_ROOT", Pathname.new(dir))
        allow(Mimic::Util::Probes).to receive(:which).and_return("/usr/bin/tool")
        instance = builder
        stub_build(instance, dir, "ik_llama.cpp")

        src = instance.build("ik_llama.cpp")
        built_dir = Pathname.new(src).dirname.dirname.dirname

        expect(built_dir).to eq(Pathname.new(dir) / "ik_llama.cpp")
      end
    end

    it "exits when a build tool is missing" do
      allow(Mimic::Util::Probes).to receive(:which).and_return(nil)
      expect { builder.build("llama.cpp") }.to output(/'git' is required/).to_stdout.and raise_error(SystemExit)
    end
  end
end
