# Plan: give the model surface an object

Execution plan for a `Mimic::Model` refactor. Written to be executed by another
agent. Read `CLAUDE.md` and `~/studio/dotfile/claude-share/rules/ruby-style.md`
first — every rule there applies, and this plan does not repeat them.

Baseline: commit `93dc017`, `bundle exec rspec` green at **418 examples, 0
failures**. Every stage below ends with a green run and a stated example count.

The count may legitimately fall — Stage 4 deletes the `load_cache` stubs and
Stage 5 deletes class methods that no longer have callers. A drop is fine when
it is accounted for: name the removed examples and say what covers that
behaviour now. A drop you cannot explain is a regression, not a cleanup.

## Why

`ruby-style.md`, "Objects, Not Main Functions":

> If the same argument is threaded through most functions in a file (`cfg`,
> `client`, `path`, `user`), it is the object. Make it a class, take it in
> `initialize`, drop it from every signature.

`model_path` is that argument. It is threaded through:

- `Gguf` — 8 of its 9 public methods take `path` (`gguf.rb:42,69,75,84,89,103,120,138`)
- `Vram.preflight(model_path, ctx, cache_type)` and `Vram.projector_bytes` (`vram.rb:53,109`)
- `LlmConfig::CtxStore` / `MmprojStore` / `ComputeStore` — every method's first argument (`llm_config.rb:133,140,170,174,206,210`)
- `Engine::IkLlama.load_cache` — a Hash keyed by model path (`ik_llama.rb:22`)
- `ChatTemplate.new(model_path, model_alias:)` (`chat_template.rb:91`)

`Mimic::ModelFile` already exists and is the right object — it just stopped at
file identity (path, alias, projector, `embedding?`). Everything else keyed by
the same path stayed outside it.

`ModelsTable#row` (`models_table.rb:40-50`) is the evidence: it receives a
`ModelFile` and then reaches around it into five other sources to fill one row.

The engine README's refactor does **not** cover this. That one was
`ruby-style.md`'s "Families of Implementations" — many classes, one job, fixed
with `Base` + a registry table. This is the earlier and more basic rule. Do not
model this refactor on the engine one; in particular **do not** introduce a
`Model::Base` or a family of model subclasses. There is one kind of model.

## Risk assessment

Measured on commit `93dc017` by grep over `lib/` and `spec/`. CodeGraph's
blast-radius numbers were checked against this and **under-report** — it listed
`ModelFile` as 4 callers and missed the `setup_wizard` scan path; its
"⚠️ no covering tests found" is also wrong for anything a spec reaches through
`described_class`. Trust the counts below, not a fresh `codegraph explore`.

| Target                                                                         | Call sites (lib)        | Call sites (spec)                    | Risk                                                                                   |
| ------------------------------------------------------------------------------ | ----------------------- | ------------------------------------ | -------------------------------------------------------------------------------------- |
| `Gguf.*`                                                                       | 12, across 8 files      | 1 (`support/gguf_writer.rb`)         | low — pure reads, `spec/gguf_spec.rb` has 24 examples                                  |
| stores (`CtxStore`/`MmprojStore`/`ComputeStore`, `recall_ctx`, `remember_ctx`) | 30 total across 7 files | 3 spec files                         | **highest** — writes to `~/.llm/*.json`, and `Engine::Base:130` writes on every launch |
| `Vram.preflight`                                                               | 16                      | in `spec/vram_spec.rb` (21 examples) | medium — arithmetic is pinned, the signature is not                                    |
| `ChatTemplate.new`                                                             | 3                       | `spec/chat_template_spec.rb`         | low                                                                                    |
| `IkLlama.load_cache`                                                           | 3 lib, 12 spec          | heavy stubbing in 4 spec files       | medium — the stubs are the coupling                                                    |

Specs that will need edits, with current example counts: `model_file_spec.rb`
(12), `llm_config_spec.rb` (27), `compute_store_spec.rb`, `vram_spec.rb` (21),
`models_table_spec.rb` (5), `setup_wizard_spec.rb` (29), `engine/ik_llama_spec.rb`.

Three specific hazards:

1. **The sidecar JSON files are live user state.** `~/.llm/model-ctx.json`,
   `model-mmproj.json`, `model-compute.json`, `ik-n-cpu-moe.json` hold real
   tuning the user depends on. The key is `LlmConfig.resolve_path(model_path)` —
   a **realpath**. If the refactor changes what gets used as the key, every
   existing entry silently orphans and the user's remembered contexts vanish.
   This already happened once (see CLAUDE.md, `expand_path` trap). Any stage that
   touches a store must include a spec asserting the key is still the resolved
   realpath and that an existing file written by the old code still reads back.
2. **`Engine::Base` and `Engine::IkLlama` hold only a String.** `base.rb:130`
   and `ik_llama.rb:125` reach the stores as class methods because they have no
   `ModelFile`. This is _why_ the stores are class methods, and it is the part
   that must be solved before the class-method doors can close.
3. **`llm_config.rb` is 438 lines** holding six classes. This refactor removes
   three of them; do not also split the remainder in the same pass.

## Target shape

One class, `Mimic::Model`, subject is the model's resolved path.

| Group        | Today                                         | After                                                                                                                          |
| ------------ | --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| identity     | `ModelFile`                                   | `path`, `real`, `model_alias`, `scan_dir` — unchanged                                                                          |
| header facts | `Gguf.moe?(path)` etc.                        | `model.header.moe?`, `.embedding?`, `.block_count`, `.ternary_packing`, `.expert_bytes_per_layer`                              |
| companions   | `ModelFile.projector_for`, `ChatTemplate.new` | `model.projector`, `model.chat_template`                                                                                       |
| remembered   | three `*Store` modules + `IkLlama.load_cache` | `model.last_ctx`, `model.compute_mib(ctx, cache)`, `model.n_cpu_moe`, `model.remember_ctx(...)`, `model.remember_compute(...)` |
| estimate     | `Vram.preflight(path, ctx, cache)`            | `model.preflight(ctx, cache)`                                                                                                  |

Four constraints on that shape:

- **`Gguf` stays a module of class methods.** A stateless byte reader over a
  path is the exception both `ruby-style.md` and `CLAUDE.md` name explicitly.
  The change is that `Model::Header` becomes its only caller.
- **`Vram` keeps the card, `Model` takes the model.** `gpu_total_mib`,
  `CACHE_BPE`, `compute_default`, `DESKTOP_RESERVE_MIB`, `gpu_process_mib` are
  host/card knowledge and stay. `kv_elems_per_token`, `projector_bytes` and the
  weights arithmetic move onto `Model`, because those three take a model.
- **`Model::Header` is a sub-object, not a flattened surface.** `Model` lands
  near 15 public methods otherwise, which is the threshold `Settings` already
  trips at 26 (see CLAUDE.md). Keep the GGUF-derived facts behind `model.header`.
- **The stores become one class.** `CtxStore`, `MmprojStore` and `ComputeStore`
  are the same read/merge/write over a different filename with a different value
  shape. Per `ruby-style.md`, "two constant tables kept in sync by a test are one
  table" — same logic one level up. One `Model::Store` taking the sidecar
  `Pathname` in `initialize`, three instances.

## Stages

TDD, per `CLAUDE.md`: failing spec first, watch it fail, then implement. One
stage per commit. `bundle exec rspec` green before moving on; say the number.

Do not start a stage before the previous one is committed. If a stage turns out
larger than described, stop and report rather than merging two stages.

### Stage 1 — `Model::Store`

Extract the shared read/merge/write of the three sidecar stores into
`Mimic::Model::Store`, instantiated with the sidecar path. Keep
`CtxStore`/`MmprojStore`/`ComputeStore` as thin wrappers over instances so no
call site changes yet.

Value shapes differ (ctx stores a two-key Hash, mmproj a String, compute a
nested `"ctx:cache" => mib` Hash), so `Store` owns the file and the key
resolution, and each wrapper owns its value shape.

Must-have specs: existing on-disk JSON written by the old code still reads back;
key is still `LlmConfig.resolve_path`; a corrupt/absent file still yields `{}`
(the `rescue SystemCallError, JSON::ParserError` behaviour at `llm_config.rb:154`).

### Stage 2 — `Settings#model`

Give `LlmConfig::Settings` a memoized `model` returning a `Model` for the
configured path. This is what closes hazard 2.

Then change `Engine::Base:130`, `Engine::IkLlama:125`, `SetupWizard:225` and
`BenchmarkWizard:60` to go through it. Behaviour must be identical — these are
the launch paths, and a mistake here means a server that will not start.

### Stage 3 — `Model::Header`

Move the `Gguf.*` calls behind `model.header.*`. Update `ModelsTable:63`,
`SetupWizard:198`, `MoeWizard:35,76`, `Services::Embed:30`,
`Engine::IkLlama:129`, `ChatTemplate:101`.

Memoize the metadata read once per model — today `ModelsTable` re-reads the
GGUF header per row per column. Note in the commit whether `llm models` got
faster; `../performance-llm-models.md` is the existing baseline.

### Stage 4 — remembered state onto `Model`

Move the store wrappers' public surface onto `Model` instance methods
(`last_ctx`, `compute_mib`, `n_cpu_moe`, `remember_*`). Fold
`IkLlama.load_cache`/`save_cache` in as a fourth `Store` instance.

The `load_cache` stubs in `models_table_spec`, `moe_wizard_spec`,
`setup_wizard_spec` and `engine/ik_llama_spec` come out here — that stubbing is
the coupling this stage removes. Do not preserve them.

### Stage 5 — `Model#preflight`, and rename

Move the model half of `Vram.preflight` onto `Model`; `Vram` keeps the card
half. Then rename `ModelFile` to `Model` (`model_file.rb` → `model.rb`,
`model_file_spec.rb` → `model_spec.rb`) and delete the class-method doors on the
stores that now have no callers.

Do the rename **last**. Renaming first makes every intermediate diff unreadable.

## Out of scope

- `LlmConfig::Settings`' 26 public methods and the `cfg.model.*` / `cfg.llama.*`
  sub-object question. It is an open decision in `../next.md` and interacts with
  `Model::Header` — but it is a separate pass and needs its own decision first.
- The `Sampling` per-model storage entry in `../next.md`. It will want a home on
  `Model` once this lands; that is a follow-up, not part of this.
- `llm model sync` (`../next.md`). It becomes a fourth `Store` instance after
  Stage 1, which is the point — but do not build it here.
- Splitting `llm_config.rb` into more files.

## Done means

- `bundle exec rspec` green, example count stated. If it is below 418, every
  missing example is named and its behaviour is accounted for elsewhere.
- No caller outside `Model` passes a model path to `Gguf`, a `*Store`, or
  `Vram.preflight`.
- `~/.llm/model-ctx.json` and its siblings read back the entries they held
  before the refactor — verified against a **copy** in a temp `HOME`, never
  against the real one (`CLAUDE.md`, working rules).
- `lib/mimic/engine/README.md` untouched; if the model surface wants prose, it
  gets its own `lib/mimic/model/README.md`, and only if asked.
- Report what was not verified. Live-server behaviour is not covered by the
  suite — say so rather than implying it was checked.
