require "open3"
require "etc"
require "pathname"
require_relative "../paths"
require_relative "../util/host"
require_relative "registry"

module Mimic
  module EngineCli
    module Source
      LAST_GOOD_DIR = Paths::LLM_ROOT / "last-good"

      BASE_BUILD_FLAGS = ["-DCMAKE_BUILD_TYPE=Release"].freeze

      class << self
        def local_status(name)
          repo = Registry.repo(name)
          return nil unless (repo / ".git").exist?

          commit = git(repo, "rev-parse", "HEAD")
          return nil if commit.empty?

          { commit: commit[0, 9], dirty: !git(repo, "status", "--porcelain").empty? }
        end

        def build_command(name, ref: nil)
          repo = Registry.repo(name)
          checkout = ref ? "git checkout #{ref}" : "git pull --ff-only"
          "cd #{repo} && \\\n" \
            "  #{checkout} && \\\n" \
            "  #{configure_step(repo, Registry.flags(name))} && \\\n" \
            "  cmake --build build -j #{jobs} --target llama-server"
        end

        # Fetch and report how far behind upstream the engine checkout is.
        def status(name)
          repo = Registry.repo(name)
          return nil unless (repo / ".git").exist?

          branch = Registry.branch(name)
          Open3.capture2("git", "-C", repo.to_s, "fetch", "--quiet", "origin", branch)
          local = git(repo, "rev-parse", "HEAD")
          remote = git(repo, "rev-parse", "origin/#{branch}")
          behind = git(repo, "rev-list", "--count", "HEAD..origin/#{branch}")
          dirty = !git(repo, "status", "--porcelain").empty?
          {
            name: name,
            repo: repo,
            branch: branch,
            local: local[0, 9],
            remote: remote[0, 9],
            behind: behind.to_i,
            dirty: dirty,
            subject: git(repo, "log", "-1", "--format=%s", "origin/#{branch}"),
          }
        end

        def record_last_good(name, sha)
          LAST_GOOD_DIR.mkpath
          (LAST_GOOD_DIR / "#{name}.sha").write("#{sha}\n")
        end

        def last_good(name)
          marker = LAST_GOOD_DIR / "#{name}.sha"
          marker.file? ? marker.read.strip : nil
        end

        private

        def configure_step(repo, engine_flags)
          return "cmake -B build" if cache_usable?(repo)

          flags = (BASE_BUILD_FLAGS + Util::Host.gpu_build_flags + engine_flags).join(" ")
          reset = (repo / "build").exist? ? "rm -rf build && \\\n  " : ""
          "#{reset}cmake -B build #{flags}"
        end

        # CMake bakes absolute paths into its cache and refuses to run when
        # either no longer matches, so a moved checkout can only be rebuilt
        # from scratch.
        def cache_usable?(repo)
          cache = repo / "build/CMakeCache.txt"
          return false unless cache.file?

          cache_entry(cache, "CMAKE_HOME_DIRECTORY") == repo.to_s &&
            cache_entry(cache, "CMAKE_CACHEFILE_DIR") == (repo / "build").to_s
        end

        def cache_entry(cache, key)
          cache.each_line do |line|
            name, value = line.chomp.split("=", 2)
            return value if name == "#{key}:INTERNAL"
          end
          nil
        rescue SystemCallError
          nil
        end

        def git(repo, *args)
          out, status = Open3.capture2("git", "-C", repo.to_s, *args)
          status.success? ? out.strip : ""
        end

        def jobs
          [(Etc.nprocessors || 4) - 2, 1].max
        end
      end
    end
  end
end
