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
        hs.execute("open owlet://rewrite")
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
