# llm-mimic-rb — rules for agents editing this repo

This repo is **live**: `~/.local/bin/{llm,mimic}` symlink to `exe/*`. Every
change here runs on the user's real machine against `~/.llm`, `~/.mimic`,
`~/.hermes`, and other tools' config files. There is no rollback -- the old
Python implementation and its cutover scripts are retired under `../archives/`
and are not maintained.

## When a spec contradicts your instinct, the spec wins

Some divergences from earlier designs are deliberate and are locked by a
spec -- `spec/engine_cli/source_spec.rb:47` pins the `ik_llama.cpp` build directory
against a known-buggy naming scheme it deliberately does not replicate. Do not
"fix" a locked spec to match what looks more consistent. Check
`../archives/audit-llm-mimic-rb.md` first; if the divergence isn't listed there, ask.

Smells that were measured, judged acceptable, and left alone on purpose -- do not
"clean" them up:

- `agent/codex.rb`'s `model_catalog` is a flat 20-key data literal because Codex's
  config format dictates the shape. It is data, not logic.
- `spec/engine/llama_spec.rb`'s three `send(:model_loaded?)` calls pin a
  regression whose only other path is a live server -- the exception
  `ruby-style.md` explicitly allows.
- Boundary stubs in `util/probes_spec`, `engine/vram_spec`, `agent/claude_spec` and
  `engine_cli/diffusion_spec` stub `/proc`, `nvidia-smi` and `PATH` because the
  alternative is stubbing the kernel.

## Design rules

- **Objects, not modules of free functions.** If the same argument is threaded
  through most functions in a file (`cfg`, `client`, `path`), that argument is
  the object: make it a class, take it in `initialize`, drop it from every
  signature. Reserve a helper module for genuinely stateless helpers with no
  shared subject -- these live under `Mimic::Util` (`Util::Fmt`, `Util::Probes`,
  `Util::Host`), alongside `Engine::Vram`'s GGUF byte readers.
- **`module_function` is banned; use `class << self`.** Under
  `module_function` a plain `private` does not touch the singleton methods
  callers actually reach, so "every class declares its private surface" is
  unexpressible. It is also a mode switch (a method appended below the macro
  silently becomes a module function, one added above silently does not) and
  it leaves a private instance-method twin of everything, which an `include`
  would inject. `class << self ... private ... end` behaves the way the rest
  of the repo assumes.
- **`cfg` belongs in an ivar**, set once in `initialize`, not recomputed at
  every call site or passed down a call chain.
- **Config is read through its section object, never a flat accessor on
  `Settings`.** `Settings` exposes `model`, `llama` and `embed` mirroring the
  YAML sections -- `cfg.model.context_length`, `cfg.llama.port`,
  `cfg.model.sampling`. `cfg.model.file` is the `Mimic::Model` for the
  configured path, rebuilt when the path changes. Adding a `cfg.port`-style
  delegator back onto `Settings` rebuilds the 28-method flat surface this
  replaced; put the accessor on the section that owns the key instead.
- **A section object reads through `section` and writes through `writable`.**
  An absent section reads as an empty hash and only a write materialises it,
  so a partial config keeps exactly the sections it carries. Never rebuild a
  section hash from known keys -- `~/.llm/config.yaml` carries keys no
  accessor knows about (`model.backend`) and `save` has to preserve them.
- **`Settings#save` writes `@cfg.slice("model", "llama", "embed")` and nothing else.** A
  hand-added top-level key in `~/.llm/config.yaml` is dropped on the next save.
  All four writers (`llm setup`, `llm path`, `llm config`, `mimic setup`) agree on
  this; don't reintroduce a full-hash write for one of them.
- **All terminal output goes through `Mimic::Ui`.** `Ui.green/red/yellow/cyan/
gray/bold`, `Ui.banner/panel/table`, and `Ui::Prompt` (`select`/`ask`/`yes?`)
  are the whole surface; nothing else names `CLI::UI`. The TTY toolkit was
  swapped out in 2026-08 after five years without a release, and the point of
  the boundary is that the next swap is one file. `Ui::Prompt` stays an
  injected collaborator (`prompt:` kwarg) rather than a module call so wizard
  specs keep a seam that isn't a global stub.
- **Symbol keys inside the app, string keys only at the YAML/JSON boundary.**
  Config parsed off disk crosses into string-keyed Hashes because that's what
  the file format gives you; anything constructed and consumed purely in Ruby
  (`Engines.status`, `Engine::Vram.preflight`) stays symbol-keyed.

## Ruby traps this port has already fallen into

- **`raise SystemExit, "message"` exits 0 and prints nothing.** A String is a
  _message_; status stays 0, and Ruby prints nothing for an uncaught
  `SystemExit`. Five sites shipped this way. Use `abort "msg"` (stderr + exit 1).
  `raise SystemExit, <Integer>` is fine.
- **Moving a file into a namespace can silently repoint its bare constants.**
  `Mimic::LlmCli::Paths` is a Thor subcommand, so a file moved under `LlmCli`
  resolves bare `Paths::LLM_ROOT` to it and dies with `uninitialized constant`.
  Lexical lookup checks the enclosing namespace before `Mimic`. After any such
  move, grep the moved file for bare references to its new siblings' names and
  qualify them (`Mimic::Paths::…`).
- **`reline` and `readline` are not default gems on Ruby 4.0.** This box runs
  4.0.1, where cli-ui's `prompt.rb` requires both at load and dies with
  `cannot load such file -- readline`. `reline` is therefore an explicit
  gemspec dependency; do not "clean up" that seemingly-stdlib entry.
- **cli-ui's own `Table` renders through `CLI::UI.puts`, which hard-wraps.**
  Both `puts_table` and `capture_table` fold a wide model board into
  fragments at the terminal width. `Ui.table` pads columns itself and
  measures with `CLI::UI::ANSI.printing_width` so colour escapes don't count.
- **Narrow `rescue` clauses swallow less than they look like they do.**
  `rescue Errno::ENOENT` covers one errno; an unreadable file took down all of
  `llm sync` because the real failure was a different errno. Prefer the wider
  `SystemCallError`. Same idea for `Psych::SyntaxError` vs `Psych::Exception`,
  and `Psych.safe_load` needs `permitted_classes: [Symbol, Date, Time]` to
  accept what a YAML file legitimately carries.
- **A raise inside a per-client/per-model loop kills the whole run.** Return
  `nil`/`false` from the helper and let the loop continue past one bad entry
  instead.
- **`IO#seek` issues a real `lseek(2)` every call.** A line-for-line seek loop
  can be ~5x slower than it looks like it should be -- see
  `../archives/llm-models-query-performance-issue.md`.
- **Thor**: `def self.exit_on_failure? = true` must stay, or error paths print
  a deprecation warning and exit 0.
- **`expand_path` does not resolve symlinks.** `~/hf-models` is a tree of
  per-file symlinks into their `.lmstudio` targets, and anything keyed by
  model path has to resolve through them or it splits into two disagreeing key
  sets (this already happened to `~/.llm/model-ctx.json`). Model paths go
  through `LlmConfig.resolve_path`, and `select_model` returns a `realpath`.
  Use that helper rather than a bare `expand_path` for anything keyed by model
  path.

## Working rules

- **TDD, no exceptions.** Write the failing spec first, watch it fail, then fix.
  Every bug listed above lived in code the suite "covered" and never exercised.
- **No comments unless the surrounding code has them**, and no new `.md` files
  unless asked. Explanatory comments in this repo are reserved for non-obvious
  external behaviour (llama.cpp preset quirks, GGUF layout) -- not for describing
  what the code does.
- `bundle exec rspec` must be green before you hand back. Say the number.
- Don't touch `~/.llm`, `~/.mimic`, or client configs from a test or a
  verification run. Copy them into a temp `HOME` first -- that guarantee has held
  through the whole port and should keep holding.
- Report what you did not verify. "Parity for module X is unproven" is a useful
  sentence; a confident summary that skips it is not.

## Scope boundaries

- `agent.rb`'s Unsloth-replacement launchers are **claude and codex only**.
  Upstream Unsloth ships six agents; the other four were cut on purpose. Don't
  add them back. `Agent::Hermes` is not one of them -- Hermes is mimic's own
  agent and owns the `~/.hermes` tree (venv, config, logs, state DB).
- **Nothing is vendored from upstream unsloth.** `Agent::Claude` / `Agent::Codex`
  reimplement its launch recipe, and `../unsloth/` is a reference checkout, not a
  runtime dependency. Periodically reviewing it for changes worth reimplementing is
  a judgement pass -- see `UPSTREAM-REVIEW.md` for what counts, what to ignore, and
  the ledger of past passes.
- **`llm setup` is the only setup wizard.** `mimic` had a second one that
  duplicated its six engine/model steps and added Hermes + Claude checks; it
  was never a command, only a no-config fallback, and it went in 2026-08.
  `mimic` now aborts with "run `llm setup` first". The one thing it did that
  `llm setup` does not is `Agent::Hermes.install`, which survives behind
  `mimic install-hermes`. Don't reintroduce a `mimic setup`.
- `mimic` owns no config of its own. It reads `~/.llm/config.yaml` and writes
  other tools' files. Resist adding a settings layer -- one was deleted in
  2026-07 for being dead weight, and the `Mimic::Config` shim that outlived it
  (five Hermes paths plus two passthroughs to `LlmConfig`) went in 2026-08.
  Read config through `LlmConfig`; a path another tool owns belongs on that
  tool's own module.
