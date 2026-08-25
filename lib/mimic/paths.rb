require "pathname"

# Filesystem roots shared by the mimic and llm CLIs.
#
# The two CLIs own separate trees: LLM_ROOT is everything the inference
# engine touches, STATE_DIR is everything the agent side does. Neither
# engine claims a home directory of its own -- llama.cpp reads no config
# file and uses ~/.cache/llama.cpp only for -hf downloads, ik_llama.cpp has
# no convention at all -- so ~/.llm is ours to define.
module Mimic
  module Paths
    LLM_ROOT = Pathname.new(Dir.home) / ".llm"
    LLM_RUN_DIR = LLM_ROOT / "run"
    # Hand-maintained `<model-alias>.jinja` overrides. Present only for
    # models whose shipped template llama.cpp cannot work with; the
    # launchers pass one to the server when the file exists and ignore the
    # directory otherwise.
    CHAT_TEMPLATES_DIR = LLM_ROOT / "chat-templates"
    # Sanitized copies mimic writes itself, kept apart from the
    # hand-maintained ones so a regenerated file can never clobber a
    # decision the user made.
    GENERATED_TEMPLATES_DIR = CHAT_TEMPLATES_DIR / "generated"
    PID_DIR = Pathname.new("/tmp/llm")

    STATE_DIR = Pathname.new(Dir.home) / ".mimic"

    # Opt-in MCP servers for the agents mimic launches, in Claude Code's own
    # `mcpServers` shape. Absent means mimic wires none -- it ships no server
    # of its own and picks none for you.
    MCP_SERVERS_PATH = STATE_DIR / "mcp-servers.json"

    # Upstream nests agent homes as `auth_root()/agents/<name>`; agent.rb
    # collapses that level, so homes land directly in AGENTS_DIR. Claude is
    # the one agent whose home mimic passes in itself (CLAUDE_CONFIG_DIR);
    # it reads AGENTS_DIR to sit beside the rest.
    AGENTS_DIR = STATE_DIR / "agents"
    CLAUDE_CONFIG_DIR = AGENTS_DIR / "claude"
  end
end
