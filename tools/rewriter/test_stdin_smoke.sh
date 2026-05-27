#!/usr/bin/env bash
# Smoke test: pipe input on stdin, capture stdout.
# Asserts that the script consumes stdin (not clipboard) and writes to stdout.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HERE/.venv/bin/python3"
SCRIPT="$HERE/rewrite_prompt.py"

# Test 1: stdin → stdout
result="$(printf 'i want make python code for csv read' | "$PY" "$SCRIPT")"
[ -n "$result" ] && [ "$result" != "i want make python code for csv read" ] \
  && echo "PASS: stdin → stdout (got '$result')" \
  || { echo "FAIL: empty or unchanged output"; exit 1; }

# Test 2: empty stdin → no output, exit 0
empty="$(printf '' | "$PY" "$SCRIPT" || true)"
[ -z "$empty" ] && echo "PASS: empty stdin → silent exit" \
  || { echo "FAIL: expected empty output, got '$empty'"; exit 1; }

# Test 3: clipboard is NOT touched (write a sentinel, run script, verify clipboard unchanged)
SENTINEL="OWLET_TEST_SENTINEL_$(date +%s)"
printf '%s' "$SENTINEL" | pbcopy
printf 'rewrite this' | "$PY" "$SCRIPT" >/dev/null
got="$(pbpaste)"
[ "$got" = "$SENTINEL" ] && echo "PASS: clipboard untouched" \
  || { echo "FAIL: clipboard mutated (expected '$SENTINEL', got '$got')"; exit 1; }
