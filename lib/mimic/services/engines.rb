require "open3"
require "etc"
require "pathname"
require_relative "../paths"

module Mimic
  module Services
    module Engines
      LAST_GOOD_DIR = Paths::LLM_ROOT / "last-good"

      ENGINES = {
        "llama.cpp" => { repo: Paths::LLM_ROOT / "llama.cpp", branch: "master" },
        "ik_llama.cpp" => { repo: Paths::LLM_ROOT / "ik_llama.cpp", branch: "main" },
      }.freeze

      class << self
        def build_command(repo, ref: nil)
          checkout = ref ? "git checkout #{ref}" : "git pull --ff-only"
          "cd #{repo} && \\\n" \
            "  #{checkout} && \\\n" \
            "  cmake -B build && \\\n" \
            "  cmake --build build -j #{jobs} --target llama-server"
        end

        # Fetch and report how far behind upstream the engine checkout is.
        def status(name)
          repo = ENGINES.fetch(name)[:repo]
          return nil unless (repo / ".git").directory?

          branch = ENGINES.fetch(name)[:branch]
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
