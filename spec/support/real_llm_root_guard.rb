require "pathname"

# Fails any spec that writes under the user's real ~/.llm.
#
# Isolation is per-spec: each store constant is named in a stub_const, so a
# store added to a path the suite already exercises writes the live tree
# until someone spots it. The root is captured from Dir.home rather than from
# Paths::LLM_ROOT, which specs legitimately stub at a tmpdir.
module RealLlmRootGuard
  Violation = Class.new(StandardError)

  ROOT = (Pathname.new(Dir.home) / ".llm").to_s

  WRITE_MODES = /[wa+]/

  class << self
    def guard(path, action)
      return unless path.to_s == ROOT || path.to_s.start_with?("#{ROOT}/")

      raise Violation, "spec tried to #{action} the user's real llm root: #{path}"
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

  def open(*args, **kwargs, &)
    mode = args.first
    RealLlmRootGuard.guard(self, "write") if mode.is_a?(String) && mode.match?(WRITE_MODES)
    super
  end
end

Pathname.prepend(RealLlmRootGuard)
