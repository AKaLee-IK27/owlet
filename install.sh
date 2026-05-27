#!/usr/bin/env bash
# Idempotent installer for the Prompt Rewriter tool.
# Handles Ollama deps, Python venv, Hammerspoon install, init.lua wiring,
# and opening System Settings so the user can grant Accessibility permission.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$HERE/tools/rewriter/.venv"
MODEL="qwen3:8b"
ZSHRC="$HOME/.zshrc"
KEEP_ALIVE_LINE='export OLLAMA_KEEP_ALIVE=24h'
HS_INIT="$HOME/.hammerspoon/init.lua"
HS_MARKER="prompt-rewriter:hotkey"

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
  printf '\n# Keep Ollama models warm for 24h (added by prompt-rewriter)\n%s\n' \
    "$KEEP_ALIVE_LINE" >> "$ZSHRC"
fi

# ---------- Hammerspoon ----------
HAMMERSPOON_FRESHLY_INSTALLED=0
if [ -d "/Applications/Hammerspoon.app" ]; then
  echo "==> Hammerspoon already installed at /Applications/Hammerspoon.app"
elif command -v brew >/dev/null 2>&1; then
  echo "==> Installing Hammerspoon via Homebrew Cask"
  brew install --cask hammerspoon
  HAMMERSPOON_FRESHLY_INSTALLED=1
else
  echo "WARN: Hammerspoon not installed and Homebrew not found."
  echo "      Install Hammerspoon manually from https://www.hammerspoon.org/"
fi

# ---------- Owlet.app (Xcode build + self-sign + install) ----------
# NOTE: xcodebuild requires the full Xcode IDE (not just Command Line Tools).
# DEVELOPER_DIR is set explicitly because xcode-select may point at CLT-only
# path (/Library/Developer/CommandLineTools) on some machines; the full Xcode
# IDE is required for SwiftUI builds. (Plan deviation: plan omits DEVELOPER_DIR.)
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "ERROR: 'xcodebuild' not on PATH. Install Xcode (full IDE, not just" >&2
  echo "       the Command Line Tools), then re-run." >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "==> Installing xcodegen (needed to generate Owlet.xcodeproj)"
  brew install xcodegen
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

# Tell Owlet where to find the rewriter venv + script. install.sh runs from
# the repo root, so $HERE/tools/rewriter is canonical regardless of clone path.
defaults write co.greenpassport.owlet rewriterDirectory "$HERE/tools/rewriter"

# Re-register Launch Services so the owlet:// URL scheme picks up the new app.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -R -f -trusted "$OWLET_INSTALL_DIR/$OWLET_APP_NAME" 2>/dev/null || true

# Launch on first install so the user can grant Accessibility.
OWLET_FRESH_INSTALL=0
if ! pgrep -x "Owlet" >/dev/null 2>&1; then
  OWLET_FRESH_INSTALL=1
fi
open "$OWLET_INSTALL_DIR/$OWLET_APP_NAME"

if [ "$OWLET_FRESH_INSTALL" = "1" ]; then
  echo "==> Opening System Settings -> Privacy & Security -> Accessibility for Owlet"
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" \
    >/dev/null 2>&1 || true
fi

# ---------- ~/.hammerspoon/init.lua ----------
# Derive the project's path relative to $HOME so the Lua block is portable:
# moving this folder anywhere under $HOME just needs another `./install.sh`.
SCRIPT_ROOT_REL="${HERE#"$HOME/"}"
if [ "$SCRIPT_ROOT_REL" = "$HERE" ]; then
  echo "ERROR: install.sh must live under \$HOME (got: $HERE)" >&2
  exit 1
fi

mkdir -p "$HOME/.hammerspoon"
HS_BLOCK_TEMPLATE="$(cat <<'LUA'
-- ===== prompt-rewriter:hotkey BEGIN =====
-- Owlet Rewriter: fn + Control + R
-- Uses hs.eventtap because hs.hotkey.bind cannot detect the fn modifier.
-- Hammerspoon's only job here is to forward the chord as an owlet:// URL;
-- Owlet.app handles capture, popup, AX replacement.
hs.allowAppleScript(true)  -- lets `./install.sh` call hs.reload() via osascript
do
    local function trigger()
        -- -g: open in background, do NOT bring Owlet to foreground.
        -- Critical so the source app keeps focus and Owlet's AX
        -- captureSelection() reads from the right element.
        hs.execute("open -g owlet://rewrite")
    end

    if _G.__owletTap then
        _G.__owletTap:stop()
        _G.__owletTap = nil
    end

    _G.__owletTap = hs.eventtap.new(
        { hs.eventtap.event.types.keyDown },
        function(event)
            local flags = event:getFlags()
            local keyName = hs.keycodes.map[event:getKeyCode()]
            if keyName == "r"
                and flags.fn and flags.ctrl
                and not flags.cmd and not flags.alt and not flags.shift then
                trigger()
                return true
            end
            return false
        end
    )
    _G.__owletTap:start()
end
-- ===== prompt-rewriter:hotkey END =====
LUA
)"
HS_BLOCK="$HS_BLOCK_TEMPLATE"

if [ -f "$HS_INIT" ] && grep -Fq "$HS_MARKER" "$HS_INIT"; then
  echo "==> Refreshing prompt-rewriter block in ~/.hammerspoon/init.lua (path=$SCRIPT_ROOT_REL)"
  awk '
    /===== prompt-rewriter:hotkey BEGIN/ { skip=1; next }
    /===== prompt-rewriter:hotkey END/   { skip=0; next }
    !skip { print }
  ' "$HS_INIT" > "$HS_INIT.tmp" && mv "$HS_INIT.tmp" "$HS_INIT"
else
  echo "==> Adding prompt-rewriter block to ~/.hammerspoon/init.lua (path=$SCRIPT_ROOT_REL)"
fi
if [ -s "$HS_INIT" ]; then
  printf '\n' >> "$HS_INIT"
fi
printf '%s\n' "$HS_BLOCK" >> "$HS_INIT"

# ---------- Launch / reload Hammerspoon ----------
if [ -d "/Applications/Hammerspoon.app" ]; then
  if pgrep -x Hammerspoon >/dev/null 2>&1; then
    echo "==> Reloading Hammerspoon config"
    osascript -e 'tell application "Hammerspoon" to execute lua code "hs.reload()"' \
      >/dev/null 2>&1 \
      || echo "    (reload via AppleScript failed — use the menu bar icon -> Reload Config)"
  else
    echo "==> Launching Hammerspoon (it will request Accessibility permission)"
    open -a Hammerspoon
  fi

  # Only pop the Accessibility pane on a fresh Hammerspoon install — TCC
  # permission survives uninstall/reinstall via brew, so re-runs shouldn't nag.
  if [ "$HAMMERSPOON_FRESHLY_INSTALLED" = "1" ]; then
    echo "==> Opening System Settings -> Privacy & Security -> Accessibility"
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" \
      >/dev/null 2>&1 || true
  fi
fi

cat <<'EOF'

==> Install complete.

ONE manual step remains (cannot be automated — macOS security):

  In the System Settings pane that just opened, scroll to Hammerspoon
  and toggle it ON under Accessibility. If prompted, enter your password.

After that:
  - The Hammerspoon menu bar icon will appear (and stay running on login
    if you tick "Launch Hammerspoon at login" in its preferences).
  - Copy any English draft prompt, press fn+Ctrl+R, then paste.

If OLLAMA_KEEP_ALIVE was just added to ~/.zshrc, open a new terminal so
the variable is in scope when you (re)start `ollama serve`.

EOF

if [ "$OWLET_FRESH_INSTALL" = "1" ]; then
  cat <<'EOF'

NOTE: First install — Owlet needs ITS OWN Accessibility grant
(separate from Hammerspoon's, because TCC permissions don't transfer
across apps). Toggle "Owlet" ON in the pane that just opened, then
press fn+Ctrl+R to test.
EOF
fi
