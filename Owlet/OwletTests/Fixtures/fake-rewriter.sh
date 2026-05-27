#!/usr/bin/env bash
# Test fixture standing in for tools/rewriter/rewrite_prompt.py.
# Behaviors configured via env var:
#   FAKE_MODE=echo (default): uppercase whatever comes on stdin
#   FAKE_MODE=empty: print nothing
#   FAKE_MODE=slow: sleep 5 then echo
#   FAKE_MODE=fail: write to stderr, exit 1
set -e
mode="${FAKE_MODE:-echo}"
case "$mode" in
  echo)  tr '[:lower:]' '[:upper:]' ;;
  empty) cat >/dev/null ;;
  slow)  sleep 5; tr '[:lower:]' '[:upper:]' ;;
  fail)  cat >/dev/null; echo "fake failure" >&2; exit 1 ;;
esac
