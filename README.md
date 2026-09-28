# mimic-llm

`llm` manages local llama.cpp, ik_llama.cpp, and PrismML llama.cpp servers. `mimic` launches Claude
Code or Codex against it, so a local model answers instead of a hosted one.

## Requirements

- **Linux**, **Ruby 3.2+**, and an NVIDIA or AMD GPU.
- **`claude` or `codex`** installed, for the launcher you want.
- Everything else -- the inference engine included -- `llm setup` handles.

## From nothing to a local Claude Code

    gem install mimic-llm

Get one GGUF model file. This is the only step `llm` cannot do for you; it
downloads nothing. Any `.gguf` works, and unsloth publishes ready ones:

    pip install huggingface_hub
    hf download unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF \
      --include "*UD-Q4_K_XL*" --local-dir ~/models

Then:

    llm setup

It checks the box (RAM, disk, GPU backend, whether `llama-server` and `claude`
are already there), asks which engine to use, and **clones and builds it when no
binary exists** -- a CUDA build takes 10-30 minutes and needs `git`, `cmake`,
`cc`, `c++`. It then scans for GGUFs, and offers to type a path when it finds
none. Point it at `~/models`, or register the directory once with
`llm path add ~/models` so later runs list it.

The remaining steps pick a context length and whether the model thinks before
answering. Context is checked against your card's free VRAM before it is
accepted, so an oversized choice is rejected at the prompt rather than at a
failed launch. Settings land in `~/.llm/config.yaml`, and setup offers to start
the server.

    llm status

Confirms the server is up, on `http://127.0.0.1:8080` by default, and prints
what it loaded. Then:

    mimic claude

Claude Code, answered by your own model. `mimic codex` does the same for Codex.

To change anything later: `llm setup` again, or `llm config` for one value,
then `llm restart`.

`llm engines` lists all three engines with their source, branch, checkout,
revision, and binary. `llm engines update` fetches all three and rebuilds any
that are behind; restart the server to use a rebuilt binary.

If something else already owns `llm` on your `PATH` (the python `llm` CLI, most
often), the gem installs `lllm` as the same program under a free name.

## State it owns

| Path | Contents |
| --- | --- |
| `~/.llm` | engine side: `config.yaml`, checkouts, presets, chat templates, sidecar stores, `run/` (logs, launch records) |
| `~/.mimic` | agent side: isolated agent homes under `agents/`, the `bin/` PATH shim, `mcp-servers.json` |
| `/tmp/llm` | pid files for the running servers |

Neither engine claims a home directory of its own, so `~/.llm` is this gem's to
define.

## Paths it assumes rather than discovers

These are hardcoded. Nothing probes for them, and nothing errors when they are
absent — the feature that depends on one silently finds nothing.

**Models.** The default search paths are `~/hf-models` and
`~/.lmstudio/models`. Add your own with `llm path add DIR`; the list lives in
`~/.llm/config.yaml` and the defaults are only the starting point.
`Model::Upstream` also treats `~/.lmstudio/models` as the layout that names a
model's source repo, so `llm models check` reports `?` for models stored any
other way whose GGUF header names no repo either.

**Engine binary.** Each engine has its own ordered resolution list — for
llama.cpp: `llama-server` on `PATH`, then its checkout at
`~/.llm/llama.cpp/build/bin/llama-server`, then `~/.local/bin/llama-server`.
ik_llama.cpp prefers its own build over `PATH`. The current
`prism-v7-llama.cpp` accepts only its own build, since its ternary formats
need Prism kernels. `llm setup` clones and builds into `~/.llm`.

**Client configs.** `llm sync` pushes the active model alias and context length
into whichever of these already exist, and skips the rest:

| Client | File |
| --- | --- |
| crush | `~/.config/crush/crush.json` |
| opencode | `~/.config/opencode/opencode.jsonc` |
| goose | `~/.config/goose/config.yaml` (+ `custom_providers/llamacpp.json`) |
| pi | `~/.pi/agent/models.json`, `settings.json` |
| hermes | `~/.hermes/config.yaml` |

An existing config file is the only evidence a client is installed — goose in
particular gets nothing written unless its config is already there. `opencode`
is skipped, with a warning, when its `.jsonc` carries comments, since rewriting
it as JSON would drop them.

**Agent binaries.** `mimic claude` and `mimic codex` resolve `claude` and
`codex` on `PATH` and abort with an install hint when either is missing
(`MIMIC_ALLOW_INSTALL=1` lets codex through so its own installer can run).
`mimic hermes-lcc` wants `hermes`, which `mimic install-hermes` puts in an
isolated venv at `~/.hermes/venv`. All three also require llama-server to be
up, and say so rather than failing at the first request.

## MCP servers (opt-in)

`mimic claude` runs Claude Code against a config dir of its own, and wires in
whatever `~/.mimic/mcp-servers.json` names — Claude Code's own `mcpServers`
shape, merged into that dir's `.claude.json` without touching entries you added
by hand:

```json
{
  "c4ai": { "command": "python", "args": ["-m", "c4ai_mcp.fastmcp_server"] }
}
```

No file means no servers. The gem ships none and picks none for you.

`WebSearch` and `WebFetch` are denied regardless. They are Anthropic
server-executed tools; llama.cpp's `/v1/messages` bridge has no implementation
(`unsupported Responses tool type 'web_search'` in the server log) and returns
zero results rather than failing. Denying them makes that visible. An MCP server
is how you give the model internet access instead. Whatever you name has to be
runnable on its own — nothing in the example above ships with this gem.

## Development

```
bundle install && bundle exec rspec < /dev/null
```

The `< /dev/null` is required: one spec exercises cli-ui's prompt layer, which
opens Reline against the terminal and blocks forever when stdin is a tty.

To run a checkout instead of the installed gem, symlink `exe/llm` and
`exe/mimic` onto your `PATH` -- they run under plain `ruby`, so the gem
dependencies have to be on the default gem path.

The suite runs under `spec/support/real_llm_root_guard.rb`, which raises on any
write or delete under `~/.llm`, `~/.mimic`, `/tmp/llm` or a client config tree.
Point a `stub_const` at a tmpdir instead.

## Trademarks

Not affiliated with, endorsed by, or sponsored by Anthropic, OpenAI or unsloth.
"Claude", "Claude Code", "Codex" and "OpenAI" are trademarks of their respective
owners, used here only to describe what this tool interoperates with.

This project ships neither client. `mimic` launches `claude` or `codex` if you
have installed them yourself, and configures them through their own documented
settings -- `ANTHROPIC_BASE_URL` for Claude Code, `model_providers` for Codex.
No Anthropic or OpenAI credential is used or required; `Agent::Claude` unsets
`ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` before launching. Your use of
either client remains governed by its own license and terms.

Design credit: the Claude Code and Codex launch recipes are reimplementations of
[unsloth](https://github.com/unslothai/unsloth)'s `unsloth_cli/start.py`. What
was taken and what was deliberately left is recorded in `UPSTREAM-REVIEW.md`.
The Codex provider block mimic writes still carries unsloth's own profile name
(`unsloth_api`) and auth env var, so an existing `~/.codex/config.toml` keeps
working.

## License

MIT -- see [LICENSE](LICENSE). One bundled file is not MIT:
`lib/mimic/agent/codex_fallback_prompt.md` is a verbatim Apache-2.0 copy of the
Codex CLI system prompt, carried from unsloth. See [NOTICE](NOTICE).
