require "pathname"
require_relative "host"
require_relative "llm_config"
require_relative "probes"
require_relative "services/engine"

# Locates an engine's llama-server, or builds one from source when the box
# has none.
module Mimic
  class EngineBuilder
    ENGINE_REPOS = {
      "llama.cpp" => "https://github.com/ggml-org/llama.cpp.git",
      "ik_llama.cpp" => "https://github.com/ikawrakow/ik_llama.cpp.git",
    }.freeze

    BUILD_TOOLS = %w[git cmake cc c++].freeze

    def initialize(config, cli_name:, prompt:, pastel:)
      @config = config
      @cli_name = cli_name
      @prompt = prompt
      @pastel = pastel
    end

    def find_or_build(engine)
      binary = Services::Engine.for(@config).find_binary
      if binary
        puts "#{@pastel.green("#{engine} llama-server found:")} #{binary}"
        return binary
      end

      abort_with_install_guide(engine) if declined?(engine)
      build(engine)
    end

    def build(engine)
      src = LlmConfig::LLM_CONFIG_DIR / engine
      require_build_tools(engine)
      clone(engine, src) unless (src / ".git").directory?

      puts "Building #{engine} in #{src}..."
      configure(src)
      compile(src)
      built_binary(engine, src)
    end

    private

    def declined?(engine)
      action = @prompt.select(
        "#{engine} llama-server not found. What now?",
        ["Build from source now (git + cmake, CUDA if nvcc present)", "I'll install it myself (abort setup)"]
      )
      action.start_with?("I'll")
    end

    def abort_with_install_guide(engine)
      puts "Install llama-server and re-run `#{@cli_name} setup` " \
           "(build guide: #{ENGINE_REPOS.fetch(engine).delete_suffix('.git')})"
      raise SystemExit, 1
    end

    def require_build_tools(engine)
      BUILD_TOOLS.each do |tool|
        next if Probes.which(tool)

        fail_with("'#{tool}' is required to build #{engine}")
      end
    end

    def clone(engine, src)
      mirror = ENV.fetch("GH_MIRROR", "").sub(%r{/+\z}, "")
      repo = ENGINE_REPOS.fetch(engine)
      clone_url = mirror.empty? ? repo : "#{mirror}/#{repo}"
      puts "Cloning #{engine}..."
      system("git", "clone", "--depth", "1", clone_url, src.to_s, exception: true)
    end

    def configure(src)
      return if system("cmake", "-S", src.to_s, "-B", (src / "build").to_s,
                       "-DCMAKE_BUILD_TYPE=Release", *Host.gpu_build_flags)

      fail_with("cmake configure failed.")
    end

    def compile(src)
      return if system("cmake", "--build", (src / "build").to_s, "--config", "Release",
                       "-j#{Host.build_jobs}", "--target", "llama-server")

      fail_with("Build failed.")
    end

    def built_binary(engine, src)
      binary = src / "build" / "bin" / "llama-server"
      fail_with("llama-server binary not found after build.") unless binary.file?

      puts "#{@pastel.green("#{engine} built:")} #{binary}"
      binary.to_s
    end

    def fail_with(message)
      puts @pastel.red(message)
      raise SystemExit, 1
    end
  end
end
