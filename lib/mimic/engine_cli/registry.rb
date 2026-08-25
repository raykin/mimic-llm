require "pathname"
require_relative "../paths"
require_relative "../util/probes"

module Mimic
  module EngineCli
    # The one table of engines: where each one's source comes from, how its
    # build is configured, and which llama-server binaries count as its own.
    #
    # `flags` are the non-default configure options each engine's existing
    # build was made with, recovered from its CMake cache. They live here
    # because that cache was their only record, and it does not survive the
    # checkout being moved.
    #
    # `binaries` is an ordered resolution list. :build is the engine's own
    # checkout, :local is ~/.local/bin, :path is whatever `llama-server`
    # resolves to. An engine that omits :path cannot borrow another build --
    # PrismML's fork reads ternary weights no upstream build understands.
    module Registry
      DEFAULT = "llama.cpp"

      ENGINES = {
        "llama.cpp" => {
          url: "https://github.com/ggml-org/llama.cpp.git",
          branch: "master",
          flags: [],
          binaries: %i[path build local],
        },
        "ik_llama.cpp" => {
          url: "https://github.com/ikawrakow/ik_llama.cpp.git",
          branch: "main",
          flags: ["-DLLAMA_CURL=OFF", "-DGGML_SCHED_MAX_COPIES=1"],
          binaries: %i[build path],
        },
        "prism-v7-llama.cpp" => {
          url: "https://github.com/PrismML-Eng/llama.cpp.git",
          branch: "prism",
          flags: [],
          binaries: %i[build],
        },
      }.freeze

      LOCAL_BINARY = Pathname.new(Dir.home) / ".local/bin/llama-server"

      class << self
        # Every engine this build offers. Drives the setup wizard's picker, the
        # `--rollback` enum and the update sweep -- so a dev-only engine is
        # absent here in an installed gem and present in a checkout.
        def names = ENGINES.reject { |_, entry| entry[:dev] && !Paths.dev_build? }.keys

        def entry(name) = ENGINES.fetch(name, ENGINES.fetch(DEFAULT))

        def known?(name) = ENGINES.key?(name)

        def url(name) = entry(name).fetch(:url)

        def branch(name) = entry(name).fetch(:branch)

        def flags(name) = entry(name).fetch(:flags)

        def repo(name) = Paths::LLM_ROOT / (known?(name) ? name : DEFAULT)

        def for(settings)
          (settings.llama.ik? ? Engine::IkLlama : Engine::Llama).new(settings)
        end

        def binaries(name)
          entry(name)[:binaries].map { |kind| resolve(kind, name) }
        end

        # Callers that must have *this* engine's binary rather than any
        # llama-server on the box.
        def builds(name)
          entry(name)[:binaries].reject { |kind| kind == :path }.map { |kind| resolve(kind, name) }
        end

        def installed_binary
          candidates = [Util::Probes.which("llama-server"), *names.flat_map { |name| builds(name) }]
          candidates.compact.map(&:to_s).find { |c| File.file?(c) }
        end

        private

        def resolve(kind, name)
          case kind
          when :path then Util::Probes.which("llama-server")
          when :local then LOCAL_BINARY
          else repo(name) / "build/bin/llama-server"
          end
        end
      end
    end
  end
end
