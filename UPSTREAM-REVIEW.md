# Upstream unsloth review log

`Agent::Claude` and `Agent::Codex` reimplement upstream unsloth's launch recipe
natively. **Nothing is vendored**, so there is no file to copy and no SHA that has
to match -- this is a periodic read-and-judge pass over upstream's
`unsloth_cli/commands/start.py`, and this file is its ledger. Run it with
`/review-unsloth` (`../.claude/commands/review-unsloth.md`).

The archived `/resync-unsloth` under `../archives/mimic-llm/` is the retired Python
port's file-copy procedure. It does not apply.

## Nothing here is a compatibility obligation

No mimic code reads `../unsloth/` at runtime; it is a reference checkout, not a
dependency. `unsloth_api` / `UNSLOTH_STUDIO_AUTH_TOKEN` are frozen by the live
`~/.mimic/agents/codex/config.toml` that `Agent::Codex.write_config` merges
into, **not** by upstream -- upstream renaming them is a non-event. The pass is
purely opportunistic: new flags, env vars, or config keys that make Claude Code or
Codex behave better against llama-server.

## What counts as a finding

Report only changes that reach a surface mimic actually has:

- a flag, env var, or config key the `claude` / `codex` command builds
- `_claude_settings_overlay` -- mirrored by `Agent::Claude`'s `--settings` overlay
- the codex `config.toml` recipe: profile, provider block, `approval_policy`,
  `sandbox_mode`, `tui.*`
- a client version gate: `_CODEX_MODEL_CATALOG_MIN_VERSION`, `_claude_version`

Ignore, and say you ignored it rather than summarising it:

- anything reaching the Unsloth Studio HTTP API -- `_connect`, `_resolve_model`,
  `_loaded_models`, model load/unload/eviction, `UNSLOTH_STUDIO_URL`. mimic points
  agents straight at llama-server and never talks to Studio.
- HF hub lookups, GGUF-variant discovery, quant/split/endianness validation.
  Model selection here is `~/.llm/config.yaml` plus `ModelFile`, not the hub.
- Windows/WSL, installers, `_studio_*` runtime/deps modules, upstream's own tests.
- opencode, goose, pi, openclaw -- cut on purpose, see `CLAUDE.md`. Do not port back.

## Ledger

Newest first. Each entry records the HEAD reviewed **up to**, which is where the
next pass starts.

### 2026-08-19 -- up to `cabed07f9`, nothing to port

Two commits touched `start.py` since `3bbed688a`:

- `1b48147d8` -- Windows: resolve the launcher through `sys.executable` instead of
  `shutil.which("unsloth")` in `_start_studio_server`, because PATHEXT picks the
  denied `unsloth.exe` over the `.cmd` shim (upstream issue #8490). Windows-only,
  and the call it fixes spawns `unsloth run` -- the Studio server. mimic points
  agents straight at llama-server and never spawns that.
- `7116d5e6c` -- comment only, +8 lines and no code, explaining why
  `_hermes_resume_oneshot_args` re-adds `--yolo` / `--accept-hooks` to a resumed
  one-shot. Upstream's Hermes wrapper, not `Agent::Hermes`, and nothing to port
  from a comment.

No new flags, env vars, config keys, version gates, or `_claude_settings_overlay`
change. Claude and Codex recipes untouched.

Note on the fetch: `git pull --ff-only` reported "unable to update local ref" for
two unrelated `studio/*` remote branches, so that fetch was partial. `main` is
level with `origin/main` at `cabed07f9`, which is what this pass reads.

### 2026-08-11 -- up to `3bbed688a`, nothing to port

Two commits touched `start.py` since `92106ea1f`:

- `e5c55e357` -- validate an explicit GGUF variant before unloading the resident model
- `bece6d2ab` -- preflight the Codex GGUF check before loading the model (+660 lines)

Both are Unsloth Studio model-management: `_preflight_codex_gguf` /
`_attach_gguf_check_for_codex` hang off `_connect` -> `_resolve_model`, which talk to
the Studio HTTP API and the HF hub to decide whether a repo has a usable GGUF before
evicting a loaded model. mimic has no Studio API, no model load/unload, no hub
lookups. No new flags, env vars, config keys, version gates, or
`_claude_settings_overlay` change. Claude side untouched.

Also changed upstream, out of scope: `studio.py`, `_studio_runtime_gate.py` (new),
`_studio_deps.py`, `_inference.py`.

### 2026-08-03 -- up to `92106ea1f`

Baseline recorded when the Ruby port's review item was written. The Python port's
last vendored SHA was `ef97f3c96` (`../archives/mimic-llm/lib/UPSTREAM_SHA`).
