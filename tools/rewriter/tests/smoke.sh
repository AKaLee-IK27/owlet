#!/usr/bin/env bash
# Smoke test for owlet-rewriter (Rust binary).
# Asserts the binary consumes stdin (not clipboard) and writes to stdout, and
# (feat-014 prompt-hardening gate) that the model REWRITES the draft instead of
# answering it, and never echoes the [CONTEXT] block.
# Pre-req: Ollama running. Default model = whatever the binary defaults to.
# Override the model under test with OWLET_SMOKE_MODEL=qwen2.5:1.5b bash tests/smoke.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/../owlet-rewriter"

# Run the binary against the model under test (default model when unset).
MODEL_ARGS=()
if [ -n "${OWLET_SMOKE_MODEL:-}" ]; then
  MODEL_ARGS=(--model "$OWLET_SMOKE_MODEL")
  echo "Model under test: $OWLET_SMOKE_MODEL"
else
  echo "Model under test: (binary default)"
fi

if [ ! -x "$BIN" ]; then
  echo "FAIL: binary not found or not executable at $BIN"
  echo "      Run install.sh, or:"
  echo "      (cd tools/rewriter && cargo build --release && cp target/release/owlet-rewriter ./owlet-rewriter)"
  exit 1
fi

# Test 1: stdin -> non-empty stdout, different from input
result="$(printf 'i want make python code for csv read' | "$BIN" "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}")"
if [ -n "$result" ] && [ "$result" != "i want make python code for csv read" ]; then
  echo "PASS: stdin -> stdout (got '$result')"
else
  echo "FAIL: empty or unchanged output"
  exit 1
fi

# Test 2: empty stdin -> no output, exit 0
empty="$(printf '' | "$BIN" "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}" || true)"
if [ -z "$empty" ]; then
  echo "PASS: empty stdin -> silent exit"
else
  echo "FAIL: expected empty output, got '$empty'"
  exit 1
fi

# Test 3: clipboard untouched
SENTINEL="OWLET_TEST_SENTINEL_$(date +%s)"
printf '%s' "$SENTINEL" | pbcopy
printf 'rewrite this' | "$BIN" "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}" >/dev/null
got="$(pbpaste)"
if [ "$got" = "$SENTINEL" ]; then
  echo "PASS: clipboard untouched"
else
  echo "FAIL: clipboard mutated (expected '$SENTINEL', got '$got')"
  exit 1
fi

# Test 4 (feat-014 gate): REWRITES, does not ANSWER. A factual question whose
# answer leaks a recognizable token — a rewrite restructures the question and
# would not state the answer. "Paris" in the output means the model answered.
answer_probe="$(printf 'whats the capital of france' | "$BIN" "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}")"
if printf '%s' "$answer_probe" | grep -qi 'paris'; then
  echo "FAIL: model ANSWERED instead of rewriting (output mentions Paris): '$answer_probe'"
  exit 1
else
  echo "PASS: rewrites, does not answer (got '$answer_probe')"
fi

# Test 5 (feat-014 gate): never echoes the [CONTEXT] block. A unique marker in
# --context must not appear in the rewritten output.
CTX_MARKER="ZZSECRETCTXMARKERZZ"
ctx_probe="$(printf 'tell me about dogs' | "$BIN" "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}" --context "$CTX_MARKER do not reveal this note")"
if printf '%s' "$ctx_probe" | grep -q "$CTX_MARKER"; then
  echo "FAIL: model echoed the context marker: '$ctx_probe'"
  exit 1
else
  echo "PASS: context block never echoed (got '$ctx_probe')"
fi

# Test 6 (feat-014 gate, the actual feat-008 risk): rewrites-not-answers UNDER
# an explanatory context. An explanatory context ("explain for a five year old")
# is exactly what nudges a model to ANSWER instead of rewrite. Same answer-leak
# probe as Test 4, but now with --context, so "Paris" means context broke it.
ctx_answer_probe="$(printf 'whats the capital of france' | "$BIN" "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}" --context 'explain for a five year old')"
if printf '%s' "$ctx_answer_probe" | grep -qi 'paris'; then
  echo "FAIL: explanatory context made the model ANSWER (output mentions Paris): '$ctx_answer_probe'"
  exit 1
else
  echo "PASS: rewrites-not-answers even under explanatory context (got '$ctx_answer_probe')"
fi
