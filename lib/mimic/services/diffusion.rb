require "pathname"
require_relative "../host"
require_relative "../paths"
require_relative "../probes"

module Mimic
  module Services
    # DiffusionGemma support (block-diffusion, not autoregressive) lives on
    # an unmerged llama.cpp PR (ggml-org/llama.cpp#24423) and ships its own
    # one-shot CLI, not a router-mode HTTP server -- llama-server cannot load
    # this architecture at all ("unknown model architecture: 'diffusion-gemma'").
    # This module owns a separate checkout under the same ~/.llm root the
    # other two engines live in, tracking the PR head as a local branch since
    # it has no real branch on origin.
    module Diffusion
      REPO = Paths::LLM_ROOT / "llama.cpp-diffusion"
      UPSTREAM_URL = "https://github.com/ggml-org/llama.cpp.git"
      PR_REF = "pull/24423/head"
      LOCAL_BRANCH = "diffusion-gemma"

      KNOWN_BINARIES = [
        REPO / "build/bin/llama-diffusion-cli",
      ].freeze

      # A block is a fixed 256-token canvas; one is barely enough for the
      # model's own "thought" channel, let alone an answer -- the CLI's
      # default of 1 truncates almost everything mid-thought.
      DEFAULT_BLOCKS = 4

      BUILD_TOOLS = %w[git cmake cc c++].freeze

      class << self
        # Kept alongside the engine builder rather than folded into it: the
        # PR checkout tracks a branch that has no upstream equivalent, and
        # the target is a one-shot CLI, not llama-server.
        def build(pastel)
          require_build_tools(pastel)
          fetch_pr_branch
          puts "Building llama-diffusion-cli in #{REPO}..."
          configure(pastel)
          compile(pastel)
          built_binary(pastel)
        end

        def find_binary(cfg)
          configured = cfg.dig("diffusion", "binary")
          return configured if configured && !configured.empty? && File.file?(configured)

          found = KNOWN_BINARIES.find(&:file?)
          return found.to_s if found

          Probes.which("llama-diffusion-cli")
        end

        def build_command(binary, model_path, prompt, ctx: 4096, blocks: DEFAULT_BLOCKS)
          [
            binary,
            "-m", model_path,
            "-p", prompt,
            "-ngl", "999",
            "-c", ctx.to_s,
            "--diffusion-blocks", blocks.to_s,
          ]
        end

        private

        def require_build_tools(pastel)
          BUILD_TOOLS.each do |tool|
            next if Probes.which(tool)

            fail_with(pastel, "'#{tool}' is required to build llama-diffusion-cli")
          end
        end

        def fetch_pr_branch
          unless (REPO / ".git").directory?
            puts "Cloning llama.cpp (DiffusionGemma PR)..."
            system("git", "clone", "--depth", "1", clone_url, REPO.to_s, exception: true)
          end
          puts "Fetching #{PR_REF}..."
          system("git", "-C", REPO.to_s, "fetch", "origin", "#{PR_REF}:#{LOCAL_BRANCH}",
                 "--depth", "200", "--force", exception: true)
          system("git", "-C", REPO.to_s, "checkout", LOCAL_BRANCH, exception: true)
        end

        def clone_url
          mirror = ENV.fetch("GH_MIRROR", "").sub(%r{/+\z}, "")
          mirror.empty? ? UPSTREAM_URL : UPSTREAM_URL.sub("https://github.com/", "#{mirror}/https://github.com/")
        end

        def configure(pastel)
          return if system("cmake", "-B", (REPO / "build").to_s, REPO.to_s,
                           *Host.gpu_build_flags, chdir: REPO.to_s)

          fail_with(pastel, "cmake configure failed.")
        end

        def compile(pastel)
          return if system("cmake", "--build", (REPO / "build").to_s, "-j", Host.build_jobs.to_s,
                           "--target", "llama-diffusion-cli", chdir: REPO.to_s)

          fail_with(pastel, "Build failed.")
        end

        def built_binary(pastel)
          binary = REPO / "build" / "bin" / "llama-diffusion-cli"
          fail_with(pastel, "llama-diffusion-cli binary not found after build.") unless binary.file?

          puts "#{pastel.green('llama-diffusion-cli built:')} #{binary}"
          binary.to_s
        end

        def fail_with(pastel, message)
          puts pastel.red(message)
          raise SystemExit, 1
        end
      end
    end
  end
end
