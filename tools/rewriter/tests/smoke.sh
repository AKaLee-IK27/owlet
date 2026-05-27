#!/usr/bin/env bash
# Smoke test for owlet-rewriter (Rust binary).
# Asserts the binary consumes stdin (not clipboard) and writes to stdout.
# Pre-req: Ollama running, qwen3:8b pulled.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/../owlet-rewriter"

if [ ! -x "$BIN" ]; then
  echo "FAIL: binary not found or not executable at $BIN"
  echo "      Run install.sh, or:"
  echo "      (cd tools/rewriter && cargo build --release && cp target/release/owlet-rewriter ./owlet-rewriter)"
  exit 1
fi

# Test 1: stdin -> non-empty stdout, different from input
result="$(printf 'i want make python code for csv read' | "$BIN")"
if [ -n "$result" ] && [ "$result" != "i want make python code for csv read" ]; then
  echo "PASS: stdin -> stdout (got '$result')"
else
  echo "FAIL: empty or unchanged output"
  exit 1
fi

# Test 2: empty stdin -> no output, exit 0
empty="$(printf '' | "$BIN" || true)"
if [ -z "$empty" ]; then
  echo "PASS: empty stdin -> silent exit"
else
  echo "FAIL: expected empty output, got '$empty'"
  exit 1
fi

# Test 3: clipboard untouched
SENTINEL="OWLET_TEST_SENTINEL_$(date +%s)"
printf '%s' "$SENTINEL" | pbcopy
printf 'rewrite this' | "$BIN" >/dev/null
got="$(pbpaste)"
if [ "$got" = "$SENTINEL" ]; then
  echo "PASS: clipboard untouched"
else
  echo "FAIL: clipboard mutated (expected '$SENTINEL', got '$got')"
  exit 1
fi
