require_relative "../ui"
require "pathname"
require_relative "../util/host"
require_relative "../llm_config"
require_relative "../util/probes"
require_relative "registry"

module Mimic
  module EngineCli
    class Builder
      BUILD_TOOLS = %w[git cmake cc c++].freeze

      def initialize(config, cli_name:, prompt:)
        @config = config
        @cli_name = cli_name
        @prompt = prompt
      end

      def find_or_build(engine)
        binary = Registry.for(@config).find_binary
        if binary
          puts "#{Ui.green("#{engine} llama-server found:")} #{binary}"
          return binary
        end

        abort_with_install_guide(engine) if declined?(engine)
        build(engine)
      end

      def build(engine)
        src = Registry.repo(engine)
        require_build_tools(engine)
        clone(engine, src) unless (src / ".git").directory?

        puts "Building #{engine} in #{src}..."
        configure(engine, src)
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
             "(build guide: #{Registry.url(engine).delete_suffix('.git')})"
        raise SystemExit, 1
      end

      def require_build_tools(engine)
        BUILD_TOOLS.each do |tool|
          next if Util::Probes.which(tool)

          fail_with("'#{tool}' is required to build #{engine}")
        end
      end

      def clone(engine, src)
        puts "Cloning #{engine}..."
        system("git", "clone", "--depth", "1", Registry.url(engine), src.to_s, exception: true)
      end

      def configure(engine, src)
        return if system("cmake", "-S", src.to_s, "-B", (src / "build").to_s,
                         "-DCMAKE_BUILD_TYPE=Release", *Util::Host.gpu_build_flags, *Registry.flags(engine))

        fail_with("cmake configure failed.")
      end

      def compile(src)
        return if system("cmake", "--build", (src / "build").to_s, "--config", "Release",
                         "-j#{Util::Host.build_jobs}", "--target", "llama-server")

        fail_with("Build failed.")
      end

      def built_binary(engine, src)
        binary = src / "build" / "bin" / "llama-server"
        fail_with("llama-server binary not found after build.") unless binary.file?

        puts "#{Ui.green("#{engine} built:")} #{binary}"
        binary.to_s
      end

      def fail_with(message)
        puts Ui.red(message)
        raise SystemExit, 1
      end
    end
  end
end
