# llm-mimic-rb refactor — design

Date: 2026-08-17. Baseline: `626bcc9`, 523 examples green.

## Implementation status (2026-08-18)

Both clusters are landed. Cluster 1 and the first two cluster 2 pieces are
committed in `a0a34a9`; the `Mimic::Cli` piece is in the working tree. The
suite is **578 examples, 0 failures**.

| Section | State | Notes |
| --- | --- | --- |
| 1. `Model::Gguf` + `Model::Header` | done | `Model::Schema` deleted, nine call sites moved, `spec/model/{gguf,header}_spec.rb` split; `Schema`'s name-stubs in `models_table_spec`, `moe_spec`, `setup_spec` and `ik_llama_spec` retargeted at `Header` instances |
| 2. `Util::Host` GPU readers + `Model::Footprint` | done | `Model::Vram` deleted; `gpu_total_mib`/`gpu_process_mib` are public on `Util::Host` with their first specs; `Model#preflight` replaced by `Model#footprint`, hash readers replaced by `measurable?`/`fits?`/`need_mib`/… |
| 3. `Model::Memory` | done | all five sidecars behind `Model#memory`; `LlmConfig::MmprojStore` deleted, now `Memory#mmproj`/`#mmproj=`; `N_CPU_MOE_PATH` moved to `Model::Memory` |
| 4. `Model::Library` + `Wizard::ContextPreflight` | done | `Wizard::Setup` down to 189 lines; `scan_gguf`/`chat_models`/`embedding_models`/`loadable?`/`search_dirs` and `ENGINE_TERNARY_PACKING` gone from it, `preflight_ok?`/`offloaded_to_fit?`/`offload_ceiling` moved out; specs split into `spec/model/library_spec.rb` and `spec/llm_cli/wizard/context_preflight_spec.rb` |

Deviations from the design as written, all deliberate:

- `Footprint.new` also takes `weights_bytes:`. The weights figure is
  file size plus the projector's, which is `Model`'s knowledge, not the
  header's; `Model#footprint` supplies it and `Footprint` stays header-shaped.
- `Memory.new(path, header = Header.new(path))` takes the header as a second
  argument so `Model` hands over the one it already parsed — `sampling_for`'s
  fallback resolves off the header, and a second parse per model would show up
  in `llm models`.
- `Wizard::Benchmark` was listed as a `Library` consumer but only calls
  `select_model`, which stays on the wizard — so it still takes a `Setup` and
  three consumers moved, not four.
- `Library#chat` and `#hidden` share one memoised partition and `#all` memoises
  the scan, so a wizard that asks for both lists globs the search paths once.
- `Wizard::Setup#choose_context` builds one `ContextPreflight` outside the
  re-pick loop; `#ok?` re-estimates on every call rather than memoising, which
  is what makes a second ask see the context just picked.
- `Footprint#layers_to_offload(ceiling:)` computes the deficit from its own
  `need_mib - budget_mib` rather than taking `deficit_mib:`, which is what the
  two call sites were passing anyway.

## Why

Twenty-one files in `lib/` open a `class << self` block. Most are legitimate:
`Ui`, `Util::Fmt`, `Util::Host`, `Util::Probes` and `EngineCli::Registry` are the
stateless helpers `CLAUDE.md` sanctions. Six are not — they thread one subject
through every method, which is the repo's own stated signal that the subject is
the object:

| File | Threaded argument |
| --- | --- |
| `model/schema.rb` | `path` |
| `model/vram.rb` | `model_path` / `meta` |
| `model.rb` | its own `path`, into five sidecar stores |
| `clients.rb` | `settings` / `(model_alias, ctx)` |
| `engine/base.rb` (class side) | `pid_file` / `log_file` |
| `cli.rb` | `cfg` |

`llm_cli/wizard/setup.rb` is a seventh problem of a different kind: at 289 lines
it is the repo's GGUF scanner as well as its setup wizard, so a table renderer
and two unrelated commands construct a wizard to reach `scan_gguf`.

## Scope

Two clusters, landed in order. Cluster 1 is everything that answers a question
about one GGUF on disk; cluster 2 is process management and the front ends.
This document specifies cluster 1 only — cluster 2 gets its own design once
cluster 1 has landed.

Constraint, set by the user: **internals are free, the CLI surface is frozen.**
Every command prints exactly what it prints today. Store layouts in `~/.llm`
may change if the migration is automatic, but see section 3 — none do.

## Cluster 1 — done

### 1. `Model::Schema` splits into `Model::Gguf` and `Model::Header`

`Schema` holds two unrelated layers. One is a GGUF binary reader:
`read_metadata`, `tensor_offsets`, `tensor_sizes`, `skip_value`,
`skip_string_array`, `u32`/`u64`/`read_str`/`read_scalar`, `arch_block_read?`.
The other is six predicates about an already-parsed header — `moe?`,
`embedding?`, `pooling_type`, `block_count`, `ternary_packing`,
`expert_bytes_per_layer` — each taking `path` plus an optional pre-parsed
`meta`, which is precisely the state `Model::Header` already holds.

- `Model::Gguf.new(path)` — the reader. `metadata(full: false)`, `tensors`,
  `tensor_sizes`. Owns the early-stop-on-vocab-array logic and the retry in
  full mode, and the rescue of `Errno::ENOENT`/`ArgumentError`/`EOFError`.
- `Model::Header.new(path)` — the predicates, over a `Gguf`. Keeps its
  memoisation and its `metadata` passthrough. Stops being a delegator.
- `Model::Schema` is deleted.

Consumers move from `Model::Schema.moe?(path)` to `Model::Header.new(path).moe?`.
Nine call sites; most already build a `Header` and then reach past it.

`spec/model/schema_spec.rb` splits along the same line: parser cases to
`spec/model/gguf_spec.rb`, predicate cases fold into
`spec/model/header_spec.rb`. `spec/support/gguf_writer.rb` is unaffected — it
writes bytes, it does not call the reader.

### 2. `Model::Vram` splits by subject; `preflight`'s hash becomes `Model::Footprint`

Two subjects share the file. `gpu_total_mib` and `gpu_process_mib` shell out to
`nvidia-smi` and contain no model — they move to `Util::Host`, which already
owns `total_mem_kb`, `free_home_bytes` and `backend`. Everything else is one
GGUF header plus a `(ctx, cache_type)` pair.

`Model::Footprint.new(header, ctx:, cache_type:, compute_mib: nil)`:

- readers `weights_mib`, `kv_mib`, `compute_mib`, `need_mib`, `budget_mib`,
  `total_mib`, `max_ctx`, `fits?`
- `layers_to_offload(ceiling:)` — 0 when nothing needs moving, `nil` when the
  model is dense or the ceiling cannot cover the deficit
- `nil`-returning construction is replaced by a `measurable?` predicate: today
  `Model#preflight` returns `nil` when `kv_elems_per_token` or `gpu_total_mib`
  comes back empty, and every caller tests `est.nil?`
- `CACHE_BPE`, `COMPUTE_FRACTION`, `COMPUTE_FLOOR_MIB`, `COMPUTE_CEILING_MIB`,
  `DESKTOP_RESERVE_MIB`, `compute_default`, `kv_elems_per_token`,
  `attention_layers` (hybrid-attention ceil-div) and `derived_head_dim` move here

`Model#preflight`'s seven-key hash disappears. Its two readers —
`Wizard::Setup#preflight_ok?`/`offloaded_to_fit?` and
`Engine::Base#record_compute` via `Vram.measured_overhead_mib` — read the
object instead. `measured_overhead_mib` becomes
`Footprint#measured_overhead_mib(pids:)`, since it is the same footprint
compared against what the process actually holds.

`Model::Vram` is deleted. `Model::Vram::CACHE_BPE` is referenced by name outside
the class; those references follow to `Footprint`.

### 3. Five store triads become `Model::Memory`

`Model` exposes `last_ctx`/`remember_ctx`, `compute_mib`/`remember_compute`,
`sampling_for`/`last_sampling`/`remember_sampling`/`forget_sampling`,
`n_cpu_moe`/`remember_n_cpu_moe`/`forget_n_cpu_moe` — eleven methods and four
private store readers — and `LlmConfig::MmprojStore` is a fifth sidecar sitting
in the config namespace instead. One idea ("what did the last good run of this
model use"), five accessor sets.

`Model::Memory.new(path)` owns all five. `Model#memory` exposes it.
`LlmConfig::MmprojStore` moves in as `Memory#mmproj` / `#mmproj=`.

**The five JSON files do not change.** Merging them into one document would
need a migration and buy nothing; the defect is the accessor surface, not the
layout. `Model::Store` is already the right object and is untouched, as is
`LlmConfig.resolve_path` key resolution.

`Model` keeps what is genuinely about the file on disk: `path`, `real`,
`model_alias`, `vision?`, `embedding?`, `projector`, and the class-side
`projector?`/`pair`/`projector_for`.

### 4. The scanner leaves the wizard as `Model::Library`

`Wizard::Setup#search_dirs`, `#scan_gguf`, `#chat_models`, `#embedding_models`,
`#loadable?` and `#report_hidden_models` are a model library. Four consumers
construct a `Wizard::Setup` purely to reach one of them: `LlmCli::Models`,
`LlmCli::Root#moe`, `LlmCli::Embed#embedding_models` and `Wizard::Benchmark`.

`Model::Library.new(config)`:

- `all` — the deduplicated, projector-paired scan (today's `scan_gguf`)
- `chat` — non-embedding models the configured engine can load
- `embedding` — embedding models
- `hidden` — chat models the engine's ternary packing rules exclude, so the
  wizard can still report them

`ENGINE_TERNARY_PACKING` moves with `loadable?`. `model_label` and
`select_model` are terminal UI and stay on the wizard side;
`report_hidden_models` keeps its `Ui.yellow` line in the wizard, fed by
`Library#hidden`.

The VRAM negotiation — `preflight_ok?`, `offloaded_to_fit?`, `offload_ceiling`
— becomes `Wizard::ContextPreflight`, over a `Footprint`. It is the only part of
the wizard that loops, and it prints four distinct messages.

`Wizard::Setup` is left with `initialize`, `step`, the two preset tables, and
the six steps: roughly 150 lines.

## Order of work

Bottom-up, each step green before the next, no step leaving the tree broken:

1. `Model::Gguf` + `Model::Header` (section 1)
2. `Util::Host` GPU readers, then `Model::Footprint` (section 2)
3. `Model::Memory` (section 3)
4. `Model::Library`, then `Wizard::ContextPreflight` (section 4)

## Testing

TDD as the repo requires: failing spec first, and every load-bearing claim
mutation-verified — break the code, watch exactly the intended spec go red. A
spec written against already-passing code proves nothing.

Two specific traps this refactor walks into:

- **A stub binds to the constant the call site names.** `Model::Schema` and
  `Model::Vram` are stubbed by name in `spec/model_spec.rb`,
  `spec/llm_cli/wizard/setup_spec.rb`, `spec/engine/ik_llama_spec.rb`,
  `spec/engine/llama_spec.rb` and `spec/llm_cli/models_table_spec.rb`. Deleting
  either class turns those stubs into stubs of nothing unless each one is
  retargeted — and the suite will stay green while the real code runs.
- **Output is frozen.** `llm status`, `llm models`, `llm setup` and
  `llm embed status` printing must not shift by a character. Where no spec pins
  a line today, one gets written before the code moves.

## Cluster 2 (2026-08-18) — done

Landed after cluster 1. Suite **578 examples, 0 failures**.

| Piece | State | Notes |
| --- | --- | --- |
| `Engine::Base`'s class side as a server-process object | done | `Engine::ServerProcess` with `.chat`/`.embed` named constructors holding pid file, log file and the `/proc`-scan-fallback rule as instance state; `LlamaEmbed` dropped its three overrides and `.pids`; `llm stop`/`status`/`embed stop` reach it directly. Named `ServerProcess`, not `Process` — the short name shadowed core `Process` for the whole `Engine` namespace and broke `Launcher#spawn`. `supports_mtp?` moved to `Model::Header` with a public `Model` delegator. |
| `Clients` as one object per client | done | Five classes under `lib/mimic/client/`, each owning its config path and `sync`; `Client.sync` maps the roster. `Mimic::Clients` deleted. `RealLlmRootGuard` extended to the five client config trees after a mutation run wrote the real goose provider file. |
| `Mimic::Cli` as an object | done | `Cli.new(ARGV).run`. One `COMMANDS` table (name / help blurb / menu label / handler) drives dispatch, help text and menu, replacing four parallel lists — the dead `COMMANDS` string list, the `case` arms, the `MENU` array of bound `Method` objects and the hardcoded help heredoc. `MENU_ORDER` keeps the launcher-first menu ordering as names only; help column width derives from the longest name. `mimic -h` verified byte-identical. |

Both traps above fired for real. The stale-stub one hit `spec/llm_cli/root_spec.rb`,
which stubbed the two methods that moved and so ran `#stop` against the live
process table. The frozen-output one was worse than expected: `llm stop`'s
output, `mimic -h`'s help text and every `mimic` dispatch path had no spec at
all, so each was pinned and mutation-verified before its code moved.
