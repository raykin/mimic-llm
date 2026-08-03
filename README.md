# mimic-llm (Ruby)

Ruby port of `../mimic-llm` (Python, deprecated). Manages llama.cpp/ik_llama.cpp
and launches Claude Code / Codex against it. `~/.local/bin/{llm,mimic}` symlink
into `exe/*`.

## Prerequisites

- `c4ai_mcp` importable by `python -m c4ai_mcp.fastmcp_server` (from
  `~/studio/dotfile/claude-share/c4ai_mcp`, pip-editable install). `mimic
claude` wires it in as the default internet-access MCP tool and denies the
  built-in `WebSearch`/`WebFetch` tools, since those are Anthropic
  server-executed tools that llama.cpp's `/v1/messages` bridge can't serve
  (silently returns 0 results otherwise). Same tool is already used by the
  `hermes`/`codex` flows.
