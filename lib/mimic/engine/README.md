# Mimic::Engine and Mimic::EngineCli

Two namespace modules, no behaviour on either.

`Engine` is the running AI-model engine and nothing else: a server process
speaking the OpenAI API. `EngineCli` is everything you do _to_ an engine from
the CLI — pick one, find its source, clone it, build it, update it, write its
launch preset.

| Constant                 | Role                                                                                                           |
| ------------------------ | -------------------------------------------------------------------------------------------------------------- |
| `Engine::Base`           | abstract; one server process, one log, one pid file, and the model-side prep every engine does before spawning |
| `Engine::Llama`          | mainline llama.cpp, router mode (`--models-preset`)                                                            |
| `Engine::IkLlama`        | ik_llama.cpp, direct argv + the CPU-MoE retry loop                                                             |
| `Engine::LlamaEmbed`     | the embedding/rerank server — a second llama.cpp on a second port, picked by role not by config                |
| `EngineCli::Registry`    | the engine table (url, branch, build flags, binaries) + `.for(settings)`                                       |
| `EngineCli::LlamaPreset` | writes the router preset ini                                                                                   |
| `EngineCli::Source`      | checkout status, rebuild command, last-good commit                                                             |
| `EngineCli::Builder`     | clone + cmake + compile when the box has no binary                                                             |
| `EngineCli::Update`      | how far behind upstream each checkout is                                                                       |
| `EngineCli::Status`      | the `llm status` board — config profile corrected by the running instance's own argv                           |

Two collaborators live under `engine/` without being engines: `Launcher`, which
spawns the process, and `ChatTemplate`, which prepares the model's Jinja
template before the spawn and probes the live server after it. Nothing outside
`Base` uses either, which is why they stay here rather than in a namespace of
their own.

The dependency runs both ways and that is deliberate: `Engine::Base` asks
`EngineCli::Registry` where its binary is, and `Registry.for` hands back an
`Engine::Llama` or `Engine::IkLlama`. `engine_cli.rb` requires `engine.rb`
first; the two cross-references are resolved at call time, not load time, so
the cycle never bites.

## Adding an engine

Add a row to `EngineCli::Registry::ENGINES`. That is the whole change if it is
an upstream fork that takes the same flags — no new class.

A new row needs a `binaries:` list, ordered. `:path` is `llama-server` on PATH,
`:build` is the engine's own checkout, `:local` is `~/.local/bin`. An engine
that omits `:path` cannot borrow another build; that is how prism-llama.cpp,
whose ternary weights no upstream build reads, stays isolated.

Write a class only when the launch protocol differs — different argv, different
readiness check, a retry loop. Then it is `Engine::Whatever < Base` and
`Registry.for` picks it.

`Engine::LlamaEmbed` is the one subclass `Registry` must not know about: it is
selected by role (`llm embed start`), not by `llama.engine`, and `Registry.names`
drives the setup wizard's engine picker — a row there would offer the encoder as
a chat engine.

## Per-server log and pid file

`Base.log_file` / `Base.pid_file` are singleton methods, not constants, because
a constant resolves lexically: an inherited `log_tail` would read the chat
server's log whichever subclass called it. `LlamaEmbed` overrides both, and
overrides `proc_scan_fallback?` to `false` — the `/proc` scan that finds a chat
server whose pid file went missing would match the embedding server too, since
they are the same binary.

## Why prism-llama.cpp has no class

It used to be `class PrismLlama < Llama` overriding exactly `find_binary`. A
subclass that overrides one method and adds no state is configuration wearing a
type. It is now three symbols in the registry row.

Rails does the same with MariaDB — no `MariaDBAdapter`, just a `mariadb?`
predicate on the shared abstract adapter. If a fork ever needs behaviour rather
than a different binary path, add a predicate on `Base`, not a subclass.

## Where things moved (2026-08-15)

`Services::{Llama,IkLlama,PrismLlama,LlamaPreset,Engine,Engines}`,
`Mimic::EngineBuilder`, `Mimic::EngineUpdate` all collapsed into here.
`PrismLlama` and `EngineBuilder::ENGINE_REPOS` are gone — the repo-URL table and
the repo/branch/flags table were the same three engines keyed the same way, held
in sync by a spec that asserted their keys matched.

`Engine::Embed` joined this namespace in 2026-08-16 when `Services` was
dissolved: it is a second llama-server, so it belongs beside the chat engines.
`Engine::Launcher` came across with it — the spawn mechanism every engine uses.

One behaviour change came with the merge: `Builder#configure` now passes the
registry's per-engine flags. The old builder did not, so a first-time
ik_llama.cpp build was configured without `-DLLAMA_CURL=OFF
-DGGML_SCHED_MAX_COPIES=1` while every rebuild had them.

## Where things moved (2026-08-16)

The build/manage half split back out into `Mimic::EngineCli` under
`lib/mimic/engine_cli/`, so `Engine` holds only the model-running classes.
`Registry` and `LlamaPreset` went with it even though runtime touches both —
picking an engine and writing its launch file are management jobs the running
process merely consumes.

Three files left `Engine` in the same pass, sorted by who actually calls them
rather than by where they were first written:

- `Engine::Status` → `EngineCli::Status`. Its only consumer is `llm status`, and
  rendering a board is something you do _to_ an engine from the CLI.
- `Engine::Schema` → `Model::Schema`. It is a GGUF binary reader; 9 of its 11
  call sites are `Mimic::Model` and `Model::Header`.
- `Engine::Vram` → `Model::Vram`. GGUF math plus `nvidia-smi`, consumed mostly
  by `Model#preflight` and the setup wizard. `gpu_total_mib` is the one method
  that is a machine fact rather than a model fact — if more of those arrive,
  they want their own home, not this one.

`Engine::Embed` became `Engine::LlamaEmbed < Base` in the same pass. It arrived
here depending on `Base` the awkward way — reaching in for `LOG_TAIL_BYTES`,
`cleanup_failed` and `last_lines`, and carrying its own copies of `log_tail`,
`launcher` and `first_existing`. Turning `LOG_FILE`/`PID_FILE` into overridable
singleton methods removed the reason those copies existed. It still overrides
`find_binary` (llama.cpp's own build only), `running?`/`models_url` (its own
port, `/health` for readiness) and `start` (no `remember:` to honour, so the
abstract signature on `Base` loosened to `start(**)`).
