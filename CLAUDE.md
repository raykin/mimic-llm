# llm-mimic-rb — rules for agents editing this repo

This repo is **live**: `~/.local/bin/{llm,mimic}` symlink to `exe/*`. Every
change here runs on the user's real machine against `~/.llm`, `~/.mimic`,
`~/.hermes`, and other tools' config files. There is no rollback -- the old
Python implementation and its cutover scripts are retired under `../archives/`
and are not maintained.

## When a spec contradicts your instinct, the spec wins

Some divergences from earlier designs are deliberate and are locked by a
spec -- `spec/llm_cli_spec.rb:15` pins the `ik_llama.cpp` build directory
against a known-buggy naming scheme it deliberately does not replicate. Do not
"fix" a locked spec to match what looks more consistent. Check
`../audit-llm-mimic-rb.md` first; if the divergence isn't listed there, ask.

## Design rules

- **Objects, not modules of free functions.** If the same argument is threaded
  through most functions in a file (`cfg`, `client`, `path`), that argument is
  the object: make it a class, take it in `initialize`, drop it from every
  signature. Reserve a helper module for genuinely stateless helpers with no
  shared subject (`Fmt`, `Probes`, `Host`, `Vram`'s GGUF byte readers).
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
- **Symbol keys inside the app, string keys only at the YAML/JSON boundary.**
  Config parsed off disk crosses into string-keyed Hashes because that's what
  the file format gives you; anything constructed and consumed purely in Ruby
  (`Engines.status`, `Vram.preflight`) stays symbol-keyed.

## Ruby traps this port has already fallen into

- **`raise SystemExit, "message"` exits 0 and prints nothing.** A String is a
  _message_; status stays 0, and Ruby prints nothing for an uncaught
  `SystemExit`. Five sites shipped this way. Use `abort "msg"` (stderr + exit 1).
  `raise SystemExit, <Integer>` is fine.
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
  `../performance-llm-models.md`.
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

- `agent.rb` deliberately covers **claude and codex only**. Upstream Unsloth
  ships six agents; the other four were cut on purpose. Don't add them back.
- `mimic` owns no config of its own. It reads `~/.llm/config.yaml` and writes
  other tools' files. Resist adding a settings layer -- one was deleted in
  2026-07 for being dead weight.
