#!/usr/bin/env bash
# Owlet v0.2 — idempotent installer.
# Builds Owlet.app (self-contained: own hotkey + Cmd+C capture), installs to
# ~/Applications, strips Gatekeeper quarantine, and (on upgrade) cleans up the
# old Hammerspoon hotkey block from ~/.hammerspoon/init.lua. Hammerspoon is no
# longer a dependency.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$HERE/tools/rewriter/.venv"
MODEL="qwen3:8b"
ZSHRC="$HOME/.zshrc"
KEEP_ALIVE_LINE='export OLLAMA_KEEP_ALIVE=24h'
HS_INIT="$HOME/.hammerspoon/init.lua"

# ---------- Ollama ----------
if ! command -v ollama >/dev/null 2>&1; then
  echo "ERROR: 'ollama' not found in PATH." >&2
  echo "       Install Ollama from https://ollama.com/download then re-run." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: 'python3' not found in PATH." >&2
  exit 1
fi

echo "==> Pulling model: $MODEL"
ollama pull "$MODEL"

# ---------- Python venv ----------
mkdir -p "$HERE/tools/rewriter"
if [ ! -d "$VENV" ]; then
  echo "==> Creating venv at $VENV"
  python3 -m venv "$VENV"
else
  echo "==> Reusing existing venv at $VENV"
fi

echo "==> Installing Python dependencies"
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r "$HERE/tools/rewriter/requirements.txt"

chmod +x "$HERE/tools/rewriter/rewrite_prompt.py"

# ---------- Shell env: OLLAMA_KEEP_ALIVE ----------
if [ -f "$ZSHRC" ] && grep -Fq "OLLAMA_KEEP_ALIVE" "$ZSHRC"; then
  current="$(grep "OLLAMA_KEEP_ALIVE" "$ZSHRC" | tail -1)"
  echo "==> OLLAMA_KEEP_ALIVE already set in ~/.zshrc:"
  echo "    $current"
  echo "    (leaving as-is; edit manually if you want '$KEEP_ALIVE_LINE')"
else
  echo "==> Adding OLLAMA_KEEP_ALIVE=24h to ~/.zshrc"
  printf '\n# Keep Ollama models warm for 24h (added by owlet)\n%s\n' \
    "$KEEP_ALIVE_LINE" >> "$ZSHRC"
fi

# ---------- Owlet.app (Xcode build + self-sign + install) ----------
# DEVELOPER_DIR is set explicitly because xcode-select may point at the
# Command Line Tools path; the full Xcode IDE is required for SwiftUI builds.
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "ERROR: 'xcodebuild' not on PATH. Install Xcode (full IDE, not just" >&2
  echo "       the Command Line Tools), then re-run." >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "==> Installing xcodegen (needed to generate Owlet.xcodeproj)"
    brew install xcodegen
  else
    echo "ERROR: 'xcodegen' not found and Homebrew not available." >&2
    echo "       Install xcodegen manually then re-run." >&2
    exit 1
  fi
fi

OWLET_XCODE_DIR="$HERE/Owlet"
OWLET_APP_NAME="Owlet.app"
OWLET_INSTALL_DIR="$HOME/Applications"

echo "==> Regenerating Owlet.xcodeproj"
(cd "$OWLET_XCODE_DIR" && xcodegen generate >/dev/null)

echo "==> Building Owlet.app (Release)"
BUILD_LOG="$(mktemp -t owlet-build.XXXXXX)"
if ! (cd "$OWLET_XCODE_DIR" \
       && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
          xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Release \
            -derivedDataPath build clean build > "$BUILD_LOG" 2>&1); then
  echo "ERROR: xcodebuild failed. Last 60 lines of $BUILD_LOG:" >&2
  tail -60 "$BUILD_LOG" >&2
  exit 1
fi
rm -f "$BUILD_LOG"

BUILT_APP="$OWLET_XCODE_DIR/build/Build/Products/Release/$OWLET_APP_NAME"
if [ ! -d "$BUILT_APP" ]; then
  echo "ERROR: build did not produce $BUILT_APP" >&2
  exit 1
fi

echo "==> Self-signing Owlet.app"
codesign --sign - --force --deep "$BUILT_APP"

echo "==> Installing to $OWLET_INSTALL_DIR/"
mkdir -p "$OWLET_INSTALL_DIR"
rm -rf "$OWLET_INSTALL_DIR/$OWLET_APP_NAME"
cp -R "$BUILT_APP" "$OWLET_INSTALL_DIR/"

# Strip Gatekeeper quarantine so the user doesn't see "developer cannot
# be verified" on first launch. Ad-hoc self-sign means we can't notarize.
xattr -dr com.apple.quarantine "$OWLET_INSTALL_DIR/$OWLET_APP_NAME" 2>/dev/null || true

# Tell Owlet where to find the rewriter venv + script.
defaults write co.greenpassport.owlet rewriterDirectory "$HERE/tools/rewriter"

# Re-register Launch Services so any stale URL-scheme handler bindings clear.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -R -f -trusted "$OWLET_INSTALL_DIR/$OWLET_APP_NAME" 2>/dev/null || true

# ---------- ~/.hammerspoon/init.lua cleanup ----------
# v0.2 strips the prompt-rewriter:hotkey block (if present) so old installs
# that had Hammerspoon as the hotkey owner stop firing duplicate events.
# The owlet-diag:hotkey block (debug aid) is also stripped.
# Other Lua content in init.lua is preserved.
if [ -f "$HS_INIT" ]; then
  for marker in "prompt-rewriter:hotkey" "owlet-diag:hotkey"; do
    if grep -Fq "$marker" "$HS_INIT"; then
      echo "==> Stripping $marker block from ~/.hammerspoon/init.lua"
      awk -v marker="$marker" '
        $0 ~ "===== " marker " BEGIN" { skip=1; next }
        $0 ~ "===== " marker " END"   { skip=0; next }
        !skip { print }
      ' "$HS_INIT" > "$HS_INIT.tmp" && mv "$HS_INIT.tmp" "$HS_INIT"
    fi
  done
fi

# ---------- Launch + open permission panes ----------
OWLET_FRESH_INSTALL=0
if ! pgrep -x "Owlet" >/dev/null 2>&1; then
  OWLET_FRESH_INSTALL=1
fi
open "$OWLET_INSTALL_DIR/$OWLET_APP_NAME"

if [ "$OWLET_FRESH_INSTALL" = "1" ]; then
  echo "==> Opening System Settings -> Privacy & Security -> Accessibility"
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" \
    >/dev/null 2>&1 || true
  sleep 1  # Give the first pane time to open before triggering the second.
  echo "==> Opening System Settings -> Privacy & Security -> Input Monitoring"
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" \
    >/dev/null 2>&1 || true
fi

cat <<'EOF'

==> Install complete.

EOF

if [ "$OWLET_FRESH_INSTALL" = "1" ]; then
  cat <<'EOF'
NOTE: v0.2 first install — Owlet needs TWO macOS permissions:

  • Accessibility    — to read your selection and replace it with the rewrite
  • Input Monitoring — to detect your fn+Ctrl+R hotkey

Both panes are now open. Toggle Owlet ON in EACH, then relaunch
Owlet from /Applications. After that, fn+Ctrl+R works in every app.

Owlet will auto-launch on login from now on.
EOF
fi

if [ "$OWLET_FRESH_INSTALL" = "0" ]; then
  cat <<'EOF'
Owlet rebuilt and installed at ~/Applications/Owlet.app.

If permissions were invalidated by the new signature (ad-hoc sign means
TCC re-grant is needed on every rebuild), the launched Owlet will show
the permission modal. Re-toggle both Accessibility and Input Monitoring,
then relaunch.
EOF
fi
