require "tmpdir"
require "pathname"
require "mimic/engine_cli"

RSpec.describe Mimic::EngineCli::Source do
  around do |example|
    Dir.mktmpdir do |dir|
      @repo = Pathname.new(dir) / "ik_llama.cpp"
      @repo.mkpath
      example.run
    end
  end

  before do
    allow(Mimic::EngineCli::Registry).to receive(:repo).with("ik_llama.cpp").and_return(@repo)
    allow(Mimic::Util::Host).to receive(:gpu_build_flags).and_return(["-DGGML_CUDA=on"])
  end

  def write_cache(home:, cachefile:)
    build = @repo / "build"
    build.mkpath
    (build / "CMakeCache.txt").write(<<~CACHE)
      CMAKE_CACHEFILE_DIR:INTERNAL=#{cachefile}
      CMAKE_HOME_DIRECTORY:INTERNAL=#{home}
    CACHE
  end

  describe ".build_command" do
    it "configures with the engine's full flag list when no build directory exists" do
      command = described_class.build_command("ik_llama.cpp")

      expect(command).to include("-DCMAKE_BUILD_TYPE=Release", "-DGGML_CUDA=on",
                                 "-DLLAMA_CURL=OFF", "-DGGML_SCHED_MAX_COPIES=1")
      expect(command).not_to include("rm -rf build")
    end

    it "reuses the existing cache without repeating flags when it matches the checkout" do
      write_cache(home: @repo, cachefile: @repo / "build")

      command = described_class.build_command("ik_llama.cpp")

      expect(command).to include("cmake -B build && ")
      expect(command).not_to include("rm -rf build", "-DGGML_CUDA=on")
    end

    it "discards a cache generated under a different path and re-passes the flags" do
      write_cache(home: "/home/someone/.hermes/ik_llama.cpp", cachefile: "/home/someone/.mimic/ik_llama.cpp/build")

      command = described_class.build_command("ik_llama.cpp")

      expect(command).to include("rm -rf build", "-DGGML_CUDA=on", "-DLLAMA_CURL=OFF")
    end

    it "checks out the given ref instead of pulling" do
      expect(described_class.build_command("ik_llama.cpp", ref: "0be97a7a5")).to include("git checkout 0be97a7a5")
    end
  end
end
