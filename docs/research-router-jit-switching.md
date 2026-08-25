# JIT model switching on llama.cpp router mode — research complete, implementation never started

Research finished 2026-08-14. No code was written; the task was dropped at the
research stage. Sat in `next.md` under Low priority; removed there and summarised
here. This records what was measured so the question doesn't get re-opened from
scratch.

## The idea

One port, any model. A client request names a model alias, the router loads it and
evicts whatever is resident. LM Studio's just-in-time loading, on our own stack.

## Verdict

Not worth building on a 24 GB card. The mechanism llama.cpp provides is
**count-based, not VRAM-aware**, and on one 3090 the count that keeps us safe is 1 —
at which point the feature is a slow stop/start with extra moving parts. The value
that _is_ real on this hardware needs none of it (see "What is worth taking").

## What exists in llama.cpp

`~/.llm/llama.cpp/build/bin/llama-server --help`:

```
--models-dir PATH        directory containing models for the router server
--models-preset PATH     path to INI file containing model presets for the router server
--models-max N           for router server, maximum number of models to load simultaneously
--models-autoload, --no-models-autoload
--sleep-idle-seconds SECONDS
```

We already run in router mode, so the supervising process exists today: the parent
`llama-server` holds the port and spawns a per-model instance as a **grandchild**,
respawning on demand. mimic is already built around that shape — `probes.rb:53`,
`probes.rb:89`, `llama.rb:218`. No new daemon was ever required.

## Why it doesn't pay off here

1. **`--models-max` counts models, it doesn't measure VRAM.** At the default of 4 the
   router loads a second 16 GB model while the first is resident. With
   `n-gpu-layers = 999` (`llama_preset.rb:44`, all-GPU-or-nothing on purpose) that
   second load hard-fails instead of spilling to CPU — the OOM-respawn loop from the
   gemma incident, triggered by a routine model switch.
2. **`--models-max 1` was never verified to unload before it loads.** Unread code
   path. If the order is load-then-evict, every switch briefly wants both models
   resident and OOMs on 24 GB. This is the single unknown that would have to be
   settled first, and it gates everything else.
3. **Nothing stays warm regardless.** A switch is a full unload+load, ~20 s for 16 GB
   from page cache — the same cost as stopping and restarting the server, which is
   what we do today.
4. **Clients don't vary the model.** Every static client here (crush, opencode, pi,
   codex, the CC overlay) is pinned to one alias. Per-request routing only helps
   something that actually names a different model per request; nothing here does.

On a 48–80 GB card points 1 and 3 soften and `--models-max 2..3` becomes genuinely
useful. That is the condition that would change the verdict.

## Work it would have taken

- `render_preset()` emitting a section per GGUF rather than only the active model.
  Today `LlamaPreset#lines` (`llama_preset.rb:32`) writes exactly one `[alias]`
  section, so a request naming any other model doesn't resolve and the model never
  appears in `/v1/models`. Per-model ctx/KV would come from `~/.llm/model-ctx.json`,
  with a conservative fallback for models that have no record.
- `--models-max 1` in `build_command()`.
- **Landmine:** `entries` sets `"load-on-startup" => "true"` unconditionally
  (`llama_preset.rb:52`). Harmless with one section; with a section per GGUF every
  model loads at boot and the card OOMs before a client ever connects. That key has
  to become conditional on being the active model.

## ik_llama has no router mode at all

`~/.llm/ik_llama.cpp/build/bin/llama-server --help` matches none of `--models-dir`,
`--models-preset`, `--models-max`, `--models-autoload`, `--sleep-idle-seconds`.
No parent router, no grandchild instances. `IkLlama#build_command` is single-model by
construction (`-m`, one alias, one port), and its `render_preset` writes the
`LAUNCH_RECORD` argv line rather than an INI — the method name is inherited from the
sibling class, not evidence of a preset. `ik_llama.rb:85` says the same thing from the
other side: ik answers `/v1/models` without llama.cpp's router extensions.

So the feature would have been engine-conditional. That bites hardest because ik is
the fast path for MoE — the models most worth hot-swapping are exactly the ones that
couldn't be.

## No auto-start, either engine

A client hitting `:8080` with the server down gets ECONNREFUSED. There is no socket
activation (`~/.config/systemd/user/` holds only `kokoro-ttsd.service`) and
`llm_cli.rb:127` is the only call site in mimic that starts an engine, reached only
from `llm start`. mimic's own commands check and refuse rather than launch
(`cli.rb:89`). `--models-autoload` loads a model into an already-running router; it
cannot start the router.

## LM Studio comparison, as far as it was verified

On this machine: `~/.lmstudio/.internal/http-server-config.json` has
`"justInTimeModelLoading": true`, and `lms load --ttl <seconds>` unloads a model after
that many seconds unused (`ttlSeconds`, `uiTTL` in config).

So what is _proven_ is JIT load plus **time-based** idle unload. Whether LM Studio
also evicts to fit available VRAM was never confirmed — don't plan around it. On the
axis that is confirmed, llama.cpp has the equivalent in `--sleep-idle-seconds`.

Separately, LM Studio as an engine manager was evaluated and rejected 2026-07-23 —
perf was fine, the feature surface wasn't. Nothing here reopens that.

## What is worth taking

`--sleep-idle-seconds` on the single resident model: VRAM comes back when the card
sits idle, and it needs no multi-section preset, no eviction ordering, and no
`--models-max` change. That is the part of router mode that actually helps a 24 GB
card, and it is independent of everything above.

## Prerequisite context, already fixed

The phantom-`default` preset bug and grandchild-OOM detection were both fixed
2026-07-23, so router failures surface instead of hanging. Those fixes stand on their
own and are unaffected by dropping this.
