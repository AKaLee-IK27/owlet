#!/usr/bin/env bash
# Harness baseline verification.
# Runs the cheap, deterministic checks first so failures surface fast.
# Pass --with-smoke to also run the Ollama-backed Rust smoke test.
# Pass --with-app-tests to also run the macOS XCTest target (slow).
set -euo pipefail

WITH_SMOKE=0
WITH_APP_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --with-smoke) WITH_SMOKE=1 ;;
    --with-app-tests) WITH_APP_TESTS=1 ;;
    --all) WITH_SMOKE=1; WITH_APP_TESTS=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

echo "=== Harness Initialization ==="

echo "--- (1/3) Rust unit tests ---"
(cd tools/rewriter && cargo test)

echo "--- (2/3) Rust release build ---"
(cd tools/rewriter && cargo build --release)

echo "--- (3/3) Xcode project generate + Swift build ---"
(cd Owlet && xcodegen generate \
  && xcodebuild -project Owlet.xcodeproj -scheme Owlet \
       -configuration Debug -destination 'platform=macOS' build \
       -quiet)

if [ "$WITH_SMOKE" = "1" ]; then
  echo "--- optional: Rust smoke (requires ollama serve + qwen3:8b) ---"
  (cd tools/rewriter && bash tests/smoke.sh)
fi

if [ "$WITH_APP_TESTS" = "1" ]; then
  echo "--- optional: XCTest target ---"
  (cd Owlet && xcodebuild test -project Owlet.xcodeproj \
     -scheme Owlet -destination 'platform=macOS' -quiet)
fi

echo "=== Verification Complete ==="
echo
echo "Next steps:"
echo "  1. Read feature_list.json — pick ONE unfinished feature"
echo "  2. Implement it in scope"
echo "  3. Re-run the layer-specific command (see CLAUDE.md) before claiming done"
echo "  4. For end-of-session, also run: ./init.sh --all"
