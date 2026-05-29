# OWLET REWRITER

**Domain:** Rust CLI — stdin → Ollama API → stdout pipeline.

## OVERVIEW

Single-file Rust binary (`src/main.rs`, 419 lines). Reads text from stdin, sends to local Ollama, streams rewritten text to stdout.

## STRUCTURE

```
tools/rewriter/
├── Cargo.toml           # Package: owlet-rewriter, dependencies (reqwest, serde)
├── Cargo.lock           # Locked dependencies
├── src/main.rs          # All logic: SYSTEM_PROMPT, Ollama HTTP call, streaming
├── tests/smoke.sh       # Integration test (needs ollama serve)
├── .gitignore           # Ignores target/, .venv/
└── owlet-rewriter       # Built binary (gitignored)
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Change rewrite prompt | `src/main.rs` — `SYSTEM_PROMPT` constant | Edit string, rebuild |
| Change Ollama API call | `src/main.rs` — HTTP request builder | URL, model, streaming params |
| Change CLI args | `src/main.rs` — argument parsing | Only `--model <name>` is accepted; unknown flags are rejected so typos surface early. The prompt is a compile-time constant (`SYSTEM_PROMPT`), not a flag. |
| Run tests | `cargo test` | Unit tests in main.rs |
| Smoke test | `tests/smoke.sh` | Needs `ollama serve` + model pulled |

## CONVENTIONS

- **Single file** — all logic in `main.rs`. No module splitting.
- **stdin/stdout** — pure pipeline: read stdin → HTTP → stream stdout.
- **SYSTEM_PROMPT constant** — the rewrite instruction sent to Ollama.
- **Error to stderr** — human-readable errors go to stderr, exit non-zero.

## ANTI-PATTERNS

- **Don't split into modules** — 419 lines is intentionally single-file. Keep it that way.
- **Don't change SYSTEM_PROMPT casually** — it's tuned for rewrite behavior. Test after changes.
- **Don't skip smoke test** — `tests/smoke.sh` validates end-to-end with real Ollama.

## COMMANDS

```bash
# Build
(cd tools/rewriter && cargo build --release)

# Unit tests
(cd tools/rewriter && cargo test)

# Smoke test (needs ollama serve + qwen3:8b)
(cd tools/rewriter && cargo build --release && bash tests/smoke.sh)

# Quick run
echo "Some text to rewrite" | cargo run --release -- --model qwen3:8b
```
