# Performance: `llm models` and `llm setup`

**Fixed 2026-07-28.** `llm models` went from **5.2s to 0.24s** on 10 models
(Ruby interpreter startup alone is 0.22s, so the scan is now ~0.03s).

## Root cause

`Vram.read_metadata` is called once per model (`llm_cli.rb:145`), and `llm setup`
calls it again through `Vram.preflight` on every iteration of its context-shrink
retry loops (`llm_cli.rb:456`, `llm_cli.rb:489`, `wizard.rb:249`).

Each call cost ~0.45s (0.68s for gemma-4) because `skip_value` walked string
arrays one element at a time:

```ruby
count.times { f.seek(u64(f), IO::SEEK_CUR) }
```

For gemma-4-31B that is `tokenizer.ggml.tokens` (262,144 entries) +
`tokenizer.ggml.merges` (514,906) = 777,052 entries, i.e. ~1.5M Ruby I/O calls
per model (`read(8)` + `seek(len)` each).
Ten models x ~0.45s = ~4.5s, plus 0.22s startup and ~0.4s of glob/realpath/stat.

### Was this Ruby-specific?

Partly. `mimic-llm/src/mimic/vram.py:69` has the identical per-element loop, so
the algorithm was wrong in both ports. But on the same gemma-4 file Python takes
**0.143s** vs Ruby's **0.677s** — ~4.7x faster, because Python's
`BufferedReader` absorbs short forward seeks inside its buffer while Ruby's
`IO#seek` flushes the buffer and issues a real `lseek(2)` every time. So the
Ruby port really was the slower one, but the fix below is a parser fix, not a
Ruby fix; Python would benefit from the same change.

## Why the earlier batch-read attempt failed

The previous note blamed `Errno::EINVAL` on offsets >2 GB. **That diagnosis was
wrong** — measured on Ruby 4.0.1 / Linux:

```ruby
f.seek(3_000_000_000, IO::SEEK_CUR)   # => 3000000000, fine
f.seek(10_000_000_000, IO::SEEK_CUR)  # => 13000000000, past EOF, still fine
f.seek(-99_999_999_999, IO::SEEK_CUR) # => Errno::EINVAL (negative result)
```

`lseek(2)` takes a 64-bit `off_t`; large forward seeks are not a problem. EINVAL
only appears for a _negative_ resulting offset (or 2^63 overflow).

The real defect was structural: a GGUF string array is
`[len][bytes][len][bytes]...`, so the lengths are **interleaved with the
content** and cannot be batch-read. `f.read(count * 8).unpack("Q<*")` was
reading UTF-8 token bytes as if they were lengths, producing garbage — some of
it negative when seeked from — hence the EINVAL. `sysseek` would not have helped;
offsets were never the issue.

## The fix (two parts, both in `lib/mimic/vram.rb`)

**1. Buffered walk — `skip_string_array`.** Still one entry at a time, but
through a 1 MiB buffer: one `read` per megabyte instead of two syscalls per
entry. Full parse 0.45s -> 0.11s (~4x), byte-identical metadata.

**2. Stop before the vocab — `BIG_STRING_ARRAY = 4096`.** No caller needs
`tokenizer.*`; `moe?` and `kv_elems_per_token` only read `general.architecture`
and `{arch}.*` keys, and in every GGUF checked the architecture block precedes
the tokenizer block. `read_metadata` now aborts at the first string array longer
than 4096 entries. Parse cost drops to **~0.0003s**.

The 4096 threshold matters: `general.tags` is also a string array and sits
_before_ the arch block, so "stop at the first string array" would have been
wrong (verified — it returns arch but no `block_count`).

**Fallback for the ordering assumption.** If the parse was truncated and no
`{arch}.*` key was collected, `read_metadata` re-runs itself with `full: true`.
So a GGUF that puts the arch block behind the vocab is slow, never wrong.
`read_metadata(path, full: true)` also stays available for callers that want
every key.

## Verification

- All 18 GGUF files under `~/.lmstudio/models`: fast parse matches `full: true`
  on every key `Vram` consumes. The 11 model files collect 28-39 keys vs 37-53
  in a full parse — the omitted ones are all `tokenizer.*`, `general.file_type`,
  and `quantize.imatrix.*`. The 7 mmproj files are untouched (identical counts,
  no vocab array, already sub-millisecond before the fix).
- `llm models` output table byte-identical before/after (MoE column included).
- `llm setup` was **not** timed separately; its gain follows from the per-call
  0.45s -> 0.0003s across the retry-loop iterations, and from `read_metadata`
  having no other callers (`moe?`, `preflight`, specs — nothing else in the repo).
- `spec/vram_spec.rb` gained 4 cases: small-array skip, vocab-sized stop,
  late-arch full re-parse, truncated-array `EOFError`. Suite: 88 examples, 0
  failures.

## Not needed anymore

- **Metadata sidecar cache** — a 0.0003s parse is cheaper than the staleness
  logic (mtime/size invalidation) a cache would need.
- **C extension / FFI** — the per-call overhead is gone.
