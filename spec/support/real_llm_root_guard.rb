require "pathname"
require_relative "../../lib/mimic/paths"

# Fails any spec that writes to, or deletes from, the user's real state --
# ~/.llm, ~/.mimic, the pid dir the running servers are tracked by, and the
# config trees `llm sync` writes on other tools' behalf.
#
# Isolation is per-spec: each store constant is named in a stub_const, so a
# store added to a path the suite already exercises writes the live tree
# until someone spots it. The llm root is captured from Dir.home rather than
# from Paths::LLM_ROOT, which specs legitimately stub at a tmpdir; PID_DIR is
# read from Paths so the guard cannot drift from the constant it protects.
#
# The client roots are listed here rather than read off Client::* constants:
# a spec that stubs one of those constants would move the guard with it, and
# the guard's whole job is to stay pointed at the real path.
module RealLlmRootGuard
  Violation = Class.new(StandardError)

  CLIENT_ROOTS = %w[.config/crush .config/opencode .config/goose .pi/agent .hermes].freeze

  ROOTS = [
    (Pathname.new(Dir.home) / ".llm").to_s,
    (Pathname.new(Dir.home) / ".mimic").to_s,
    Mimic::Paths::PID_DIR.to_s,
    *CLIENT_ROOTS.map { |dir| (Pathname.new(Dir.home) / dir).to_s },
  ].freeze

  WRITE_MODES = /[wa+]/

  class << self
    def guard(path, action)
      return unless ROOTS.any? { |root| path.to_s == root || path.to_s.start_with?("#{root}/") }

      raise Violation, "spec tried to #{action} the user's real state: #{path}"
    end
  end

  def write(*, **)
    RealLlmRootGuard.guard(self, "write")
    super
  end

  def binwrite(*, **)
    RealLlmRootGuard.guard(self, "write")
    super
  end

  def mkpath(*, **)
    RealLlmRootGuard.guard(self, "create a directory under")
    super
  end

  def rename(*)
    RealLlmRootGuard.guard(self, "rename")
    super
  end

  def unlink(*)
    RealLlmRootGuard.guard(self, "delete")
    super
  end

  def delete(*)
    RealLlmRootGuard.guard(self, "delete")
    super
  end

  def open(*args, **kwargs, &)
    mode = args.first
    RealLlmRootGuard.guard(self, "write") if mode.is_a?(String) && mode.match?(WRITE_MODES)
    super
  end
end

Pathname.prepend(RealLlmRootGuard)
