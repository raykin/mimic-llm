require_relative "paths"
require_relative "util/probes"

# Coding-agent launchers pointed at mimic's own llama-server. Claude and
# Codex stand in for Unsloth Studio -- those two only, no opencode/goose/pi/
# openclaw, no --as-subagent, no auto-install -- and Unsloth Studio's HTTP
# client-key/model-resolution dance is skipped entirely, since mimic always
# points straight at llama-server. Hermes is not an Unsloth agent; it sits
# here because mimic launches it too, and it owns the ~/.hermes tree.
#
# This module holds only what the launchers share; per-agent wiring lives in
# agent/claude.rb, agent/codex.rb and agent/hermes.rb, which have almost
# nothing in common beyond spawning a process.
module Mimic
  module Agent
    AUTH_TOKEN = "llama.cpp"

    class << self
      def version_at_least?(version, floor)
        (version <=> floor) >= 0
      end

      # Ctrl+C should cancel a turn inside the agent, not kill this wrapper.
      # *env_diff* follows Process.spawn's env-hash convention: only changed
      # keys, `=> nil` to unset -- not a full replacement environment.
      def spawn_and_wait(command, env_diff)
        executable = Util::Probes.which(command.first)
        abort "`#{command.first}` not found on PATH" if executable.nil?

        previous = Signal.trap("INT", "IGNORE")
        pid = Process.spawn(env_diff, executable, *command[1..])
        Process.wait(pid)
        $?.exitstatus
      ensure
        Signal.trap("INT", previous) if previous
      end
    end
  end
end

require_relative "agent/claude"
require_relative "agent/codex"
require_relative "agent/hermes"
