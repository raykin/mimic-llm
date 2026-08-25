# mimic-llm

`llm` manages a local llama.cpp / ik_llama.cpp server. `mimic` launches Claude
Code or Codex against it, so a local model answers instead of a hosted one.

## Requirements

- **Linux.** `mimic` aborts on anything else.
- **Ruby 3.2+.**
- **A GGUF model file.** Nothing here downloads models.
- **`git`, `cmake`, `cc`, `c++`** -- only if you let `llm setup` build the
  inference engine. Not needed when `llama-server` is already on `PATH`.
- **CUDA toolkit or ROCm**, for a GPU build. The backend is detected: `nvcc`
  gives `-DGGML_CUDA=on`, `/dev/kfd` or `rocminfo` gives `-DGGML_HIP=on`,
  neither gives a CPU-only build. `nvidia-smi` alone is not enough.
- **`claude` or `codex` on `PATH`**, for the launcher you intend to use.

## Installation

    gem install mimic-llm

Installs `llm` and `mimic`. A third executable, `lllm`, is the same program
as `llm` under a name that stays reachable when something else already owns
`llm` on your `PATH` -- the python `llm` CLI, most often.

## Getting started

    llm setup
    llm start
    mimic claude

`llm setup` walks through engine, model, context preset and reasoning, then
writes `~/.llm/config.yaml` and offers to start the server. It scans
`~/hf-models` and `~/.lmstudio/models` for GGUF files; register other
directories with `llm path add DIR`. When no `llama-server` is found it offers
to clone the chosen engine into `~/.llm/<engine>` and build it there, or exits
with that engine's own build guide.

`mimic claude` requires llama-server to be up already, and says so rather than
failing at the first request. `llm sync` reporting "no SWE agent configs found"
is the expected result when no other agent is installed -- Claude Code is
configured by `mimic claude` itself, against a config dir of its own.

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
ik_llama.cpp prefers its own build over `PATH`, and prism-llama.cpp accepts
only its own, since its fork reads ternary weights no upstream build
understands. `llm setup` clones and builds into `~/.llm`.

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
bundle install && bundle exec rspec
```

To run a checkout instead of the installed gem, symlink `exe/llm` and
`exe/mimic` onto your `PATH` -- they run under plain `ruby`, so the gem
dependencies have to be on the default gem path.

The suite runs under `spec/support/real_llm_root_guard.rb`, which raises on any
write or delete under `~/.llm`, `~/.mimic`, `/tmp/llm` or a client config tree.
Point a `stub_const` at a tmpdir instead.
