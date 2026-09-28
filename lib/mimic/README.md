# Mimic — design rules and traps

Conventions the whole library is written to, and the mistakes it has already
made. `engine/README.md` covers the engine namespaces specifically.

## Design rules

- **Objects, not modules of free functions.** If the same argument is threaded
  through most functions in a file (`cfg`, `client`, `path`), that argument is
  the object: make it a class, take it in `initialize`, drop it from every
  signature. A helper module is for genuinely stateless helpers with no shared
  subject — these live under `Mimic::Util` (`Util::Fmt`, `Util::Probes`,
  `Util::Host`).
- **`module_function` is banned; use `class << self`.** Under `module_function`
  a plain `private` does not touch the singleton methods callers actually
  reach, so "every class declares its private surface" is unexpressible. It is
  also a mode switch — a method below the macro silently becomes a module
  function, one above silently does not — and it leaves a private
  instance-method twin of everything that an `include` would inject.
- **`cfg` belongs in an ivar**, set once in `initialize`, not recomputed at
  every call site or passed down a call chain.
- **Config is read through its section object, never a flat accessor on
  `Settings`.** `Settings` exposes `model`, `llama` and `embed` mirroring the
  YAML sections: `cfg.model.context_length`, `cfg.llama.port`,
  `cfg.model.sampling`. `cfg.model.file` is the `Mimic::Model` for the
  configured path, rebuilt when the path changes. A `cfg.port`-style delegator
  rebuilds the 28-method flat surface this replaced; put the accessor on the
  section that owns the key.
- **A section object reads through `section` and writes through `writable`.**
  An absent section reads as an empty hash and only a write materialises it, so
  a partial config keeps exactly the sections it carries. Never rebuild a
  section hash from known keys — `~/.llm/config.yaml` carries keys no accessor
  knows about (`model.backend`) and `save` has to preserve them.
- **`Settings#save` writes `@cfg.slice("model", "llama", "embed")` and nothing
  else.** A hand-added top-level key is dropped on the next save. All writers
  (`llm setup`, `llm path`, `llm config`, `llm embed`) agree on this; don't
  reintroduce a full-hash write for one of them.
- **All terminal output goes through `Mimic::Ui`.**
  `Ui.green/red/yellow/cyan/gray/bold`, `Ui.banner/panel/table` and
  `Ui::Prompt` (`select`/`ask`/`yes?`) are the whole surface; nothing else names
  `CLI::UI`. The TTY toolkit was swapped out in 2026-08 after five years without
  a release, and the point of the boundary is that the next swap is one file.
  `Ui::Prompt` stays an injected collaborator (`prompt:` kwarg) rather than a
  module call so wizard specs keep a seam that isn't a global stub.
- **A namespace directory may require its parent back.**
  `llm_config/{settings,model_settings,embed}.rb` each `require_relative
  "../llm_config"` and are required from it in turn. The cycle is harmless
  because every cross-reference (`Embed#model_alias` → `Settings.alias_for`,
  `Settings#model` → `ModelSettings`) resolves at call time. A load-time
  reference across that seam — a superclass, an `include`, a constant in a
  default argument — is what breaks it. Only `mimic`, `mimic/llm_config`,
  `mimic/model` and `agent/hermes` are real entry points; that the
  `llm_config/*` files load standalone is checked by hand after a move, not by
  a spec.
- **Symbol keys inside the app, string keys only at the YAML/JSON boundary.**
  Config parsed off disk is string-keyed because that is what the format gives
  you; anything constructed and consumed purely in Ruby stays symbol-keyed.

## Ruby traps this port has already fallen into

- **`raise SystemExit, "message"` exits 0 and prints nothing.** A String is a
  _message_; status stays 0 and Ruby prints nothing for an uncaught
  `SystemExit`. Five sites shipped this way. Use `abort "msg"` (stderr, exit 1).
  `raise SystemExit, <Integer>` is fine.
- **Moving a file into a namespace can silently repoint its bare constants.**
  `Mimic::LlmCli::Paths` is a Thor subcommand, so a file moved under `LlmCli`
  resolves bare `Paths::LLM_ROOT` to it and dies with `uninitialized constant` —
  lexical lookup checks the enclosing namespace before `Mimic`. After such a
  move, grep the moved file for bare references to its new siblings' names and
  qualify them (`Mimic::Paths::…`).
- **A class named for a core Ruby constant shadows it namespace-wide.**
  `Engine::Process` made `Launcher`'s `Process.spawn` resolve to the new class.
  The whole `Engine` tree was affected, not just the defining file. Hence
  `Engine::ServerProcess`.
- **`reline` and `readline` are not default gems on Ruby 4.0.** cli-ui's
  `prompt.rb` requires both at load and dies with `cannot load such file --
  readline`. `reline` is an explicit gemspec dependency; do not "clean up" that
  seemingly-stdlib entry.
- **cli-ui's own `Table` renders through `CLI::UI.puts`, which hard-wraps.**
  Both `puts_table` and `capture_table` fold a wide board into fragments at the
  terminal width. `Ui.table` pads columns itself and measures with
  `CLI::UI::ANSI.printing_width` so colour escapes don't count.
- **Narrow `rescue` clauses swallow less than they look like they do.**
  `rescue Errno::ENOENT` covers one errno; an unreadable file took down all of
  `llm sync` because the real failure was a different errno. Prefer
  `SystemCallError`, and `Psych::Exception` over `Psych::SyntaxError`.
  `Psych.safe_load` needs `permitted_classes: [Symbol, Date, Time]`.
- **A raise inside a per-client/per-model loop kills the whole run.** Return
  `nil`/`false` from the helper and let the loop continue past one bad entry.
- **`IO#seek` issues a real `lseek(2)` every call.** A line-for-line seek loop
  can be ~5× slower than it looks — see
  `docs/llm-models-query-performance-issue.md`.
- **`expand_path` does not resolve symlinks.** `~/hf-models` is a tree of
  per-file symlinks into their `.lmstudio` targets, and anything keyed by model
  path has to resolve through them or it splits into two disagreeing key sets
  (this happened to `~/.llm/model-ctx.json`). Model paths go through
  `LlmConfig.resolve_path`, and `select_model` returns a `realpath`.
- **A stub only covers the constant the call site actually names.**
  `ik_llama.rb` calls `Base.cleanup_failed(pid)` and `Base.last_lines(tail)`
  literally, not through `self.class`, so `allow(described_class)` — or worse a
  sibling — stubs nothing and the real method runs. That shipped: the ik
  retry-loop specs deleted the live `/tmp/llm/llama-server.pid` on every suite
  run and `llm status` reported `(pid ?)` for a server that was up. Read the
  call site before choosing the stub target; a passing suite does not prove the
  stub bound.
- **Thor**: `def self.exit_on_failure? = true` must stay, or error paths print a
  deprecation warning and exit 0.

## Scope boundaries

- `agent.rb`'s Unsloth-replacement launchers are **claude and codex only**.
  Upstream ships six agents; the other four were cut on purpose. Don't add them
  back. `Agent::Hermes` is not one of them — Hermes is mimic's own agent and
  owns the `~/.hermes` tree (venv, config, logs, state DB).
- **One file is vendored from upstream unsloth, and only one.**
  `agent/codex_fallback_prompt.md` is a byte-identical copy of
  `unsloth_cli/codex_fallback_prompt.md`, carrying OpenAI's Codex CLI system
  prompt — both Apache-2.0, recorded in `NOTICE`, packaged by the gemspec's
  `lib/**/*` glob. Keep it verbatim: modifying it puts the Apache-2.0 4(b)
  change-notice obligation on us and makes upstream diffs meaningless. Nothing
  else is vendored — `Agent::Claude` / `Agent::Codex` reimplement unsloth's
  launch recipe, and `../unsloth/` is a reference checkout, not a runtime
  dependency. Reviewing upstream for changes worth reimplementing is a periodic
  judgement pass, run from this machine's `/sync-unsloth-cc-codex` against an untracked
  `UPSTREAM-REVIEW.md` ledger.
- **`Engine::LlamaEmbed` is selected by role, never by config, so it must stay
  out of `EngineCli::Registry::ENGINES`.** `Registry.for(settings)` dispatches
  on `cfg.llama.engine` and `Registry.names` drives the setup wizard's engine
  picker (`llm_cli/wizard/setup.rb:70`, pinned by
  `spec/llm_cli/wizard/setup_spec.rb:43`); an entry there would offer the
  embedding server as a chat engine. The eight chat-only private methods it
  inherits and never calls were the accepted price of `Base` already being
  abstract, not an oversight to tidy.
- **`llm setup` is the only setup wizard.** `mimic` had a second one that
  duplicated its six engine/model steps; it was never a command, only a
  no-config fallback, and it went in 2026-08. `mimic` now aborts with "run `llm
  setup` first". The one thing it did that `llm setup` does not is
  `Agent::Hermes.install`, which survives behind `mimic install-hermes`. Don't
  reintroduce a `mimic setup`.
- **`mimic` owns no config of its own.** It reads `~/.llm/config.yaml` and
  writes other tools' files. Resist adding a settings layer — one was deleted in
  2026-07 for being dead weight, and the `Mimic::Config` shim that outlived it
  went in 2026-08. Read config through `LlmConfig`; a path another tool owns
  belongs on that tool's own module.
