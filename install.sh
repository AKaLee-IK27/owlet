#!/usr/bin/env bash
# Owlet v0.3 — idempotent installer.
# Builds Owlet.app (self-contained: own hotkey + Cmd+C capture), signs it with
# a stable self-signed cert in the login keychain so TCC (Accessibility / Input
# Monitoring) grants survive rebuilds, installs to ~/Applications, strips
# Gatekeeper quarantine, and (on upgrade) cleans up the old Hammerspoon hotkey
# block from ~/.hammerspoon/init.lua. Hammerspoon is no longer a dependency.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# ---------- Rust toolchain ----------
if ! command -v cargo >/dev/null 2>&1; then
  echo "ERROR: 'cargo' not found in PATH." >&2
  echo "       Install the Rust toolchain via:" >&2
  echo "         curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh" >&2
  echo "       Then re-run install.sh." >&2
  exit 1
fi

echo "==> Pulling model: $MODEL"
ollama pull "$MODEL"

# ---------- Build owlet-rewriter ----------
echo "==> Building owlet-rewriter (Rust, release)"
BUILD_LOG="$(mktemp -t owlet-rewriter-build.XXXXXX)"
if ! (cd "$HERE/tools/rewriter" && cargo build --release --quiet) > "$BUILD_LOG" 2>&1; then
  echo "ERROR: cargo build failed. Last 60 lines of $BUILD_LOG:" >&2
  tail -60 "$BUILD_LOG" >&2
  exit 1
fi
rm -f "$BUILD_LOG"

cp "$HERE/tools/rewriter/target/release/owlet-rewriter" \
   "$HERE/tools/rewriter/owlet-rewriter"
chmod +x "$HERE/tools/rewriter/owlet-rewriter"

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

# ---------- Stable code signing identity ----------
# v0.3+: sign with a self-signed cert that lives in the login keychain.
# TCC keys Accessibility / Input Monitoring grants on (bundle ID, Designated
# Requirement). The DR is derived from the signing cert, so as long as the
# same cert signs every rebuild the grant persists. Ad-hoc signing (v0.1/v0.2)
# left TCC keying on CDHash, which changes every build and forced a re-grant.
CERT_NAME="Owlet Developer"
OWLET_STATE_DIR="$HOME/.owlet"
SIGNING_SENTINEL="$OWLET_STATE_DIR/.stable-signing-active"
mkdir -p "$OWLET_STATE_DIR"

# Use `find-identity` (not `find-certificate`) so we verify the private key
# is also in the keychain — codesign needs both. A bare cert without its key,
# or a cert in a different keychain, would pass `find-certificate` but break
# the later `codesign --sign` with a cryptic error. Note: `-v` is intentionally
# omitted because it filters out self-signed certs (CSSMERR_TP_NOT_TRUSTED),
# which still work fine for codesign.
if ! security find-identity -p codesigning 2>/dev/null | grep -qF "\"$CERT_NAME\""; then
  echo "==> Creating self-signed code signing certificate '$CERT_NAME' in login keychain"
  CERT_TMP="$OWLET_STATE_DIR/signing"
  mkdir -p "$CERT_TMP"

  # OpenSSL config (works with LibreSSL shipped on macOS; -addext does not).
  cat > "$CERT_TMP/openssl.cnf" <<'CONF'
[req]
distinguished_name = req_dn
prompt = no
x509_extensions = v3_codesign

[req_dn]
CN = Owlet Developer

[v3_codesign]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF

  openssl req -new -newkey rsa:2048 -x509 -days 3650 -nodes \
    -config "$CERT_TMP/openssl.cnf" \
    -keyout "$CERT_TMP/owlet.key" \
    -out "$CERT_TMP/owlet.crt" \
    >/dev/null 2>&1

  # OpenSSL 3.x defaults to a PKCS12 MAC algorithm that macOS `security`
  # cannot verify — `-legacy` forces SHA-1 HMAC which works. LibreSSL (the
  # system /usr/bin/openssl on macOS) doesn't recognise -legacy but produces
  # the legacy format by default, so we only pass the flag when needed.
  # Separately, macOS `security import` rejects truly-empty PKCS12 passwords,
  # so a stable placeholder ("owlet") is used on both sides. It's not a real
  # secret — the cert is ultimately protected by the user's login keychain.
  PKCS12_LEGACY=""
  if openssl version 2>/dev/null | grep -q "OpenSSL 3"; then
    PKCS12_LEGACY="-legacy"
  fi
  # shellcheck disable=SC2086  # intentional word-splitting of optional flag
  openssl pkcs12 -export $PKCS12_LEGACY \
    -inkey "$CERT_TMP/owlet.key" \
    -in "$CERT_TMP/owlet.crt" \
    -out "$CERT_TMP/owlet.p12" \
    -name "$CERT_NAME" \
    -passout pass:owlet \
    >/dev/null 2>&1

  # -A = any application (including codesign) may use this private key
  # without per-use prompting. Appropriate for a personal-machine tool;
  # avoids needing the user's login keychain password to set a partition list.
  if ! security import "$CERT_TMP/owlet.p12" \
       -k "$HOME/Library/Keychains/login.keychain-db" \
       -A \
       -P "owlet" >/dev/null 2>&1; then
    echo "ERROR: failed to import signing cert into login keychain." >&2
    echo "       Try removing any old 'Owlet Developer' entries from Keychain Access" >&2
    echo "       and re-running install.sh." >&2
    exit 1
  fi

  # Sanity check: EKU made it through. If this fails the cert was imported
  # but signing might not behave as expected — surface it loudly.
  if ! security find-certificate -c "$CERT_NAME" -p \
       | openssl x509 -text -noout 2>/dev/null \
       | grep -q "Code Signing"; then
    echo "WARNING: Code Signing EKU not detected on imported cert." >&2
    echo "         codesign will still run but the DR may not lock to this cert." >&2
  fi

  rm -rf "$CERT_TMP"
else
  echo "==> Reusing existing '$CERT_NAME' certificate from login keychain"
fi

# Detect pre-v0.3 -> v0.3 migration so we can tccutil-reset once. Sentinel
# file is touched only after a successful reset, so re-running install.sh
# doesn't keep wiping the grant.
OWLET_NEEDS_MIGRATION=0
if [ ! -f "$SIGNING_SENTINEL" ]; then
  OWLET_NEEDS_MIGRATION=1
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

# ---------- Brand fonts ----------
# The v0.4 branded popup uses Fraunces (display italic) + Be Vietnam Pro (UI).
# Both ship as Homebrew casks. We install them system-wide so SwiftUI's
# Font.custom can resolve them by PostScript name; if missing, Font.custom
# silently falls back to NewYork / SF Pro and the popup still works, just
# off-brand.
# Skip silently if Homebrew is absent — same fallback applies.
if command -v brew >/dev/null 2>&1; then
  for cask in font-fraunces font-be-vietnam-pro; do
    if brew list --cask "$cask" >/dev/null 2>&1; then
      echo "==> Reusing existing brew cask '$cask'"
    else
      echo "==> Installing brew cask '$cask' (Owlet branded UI font)"
      brew install --cask "$cask" >/dev/null 2>&1 || \
        echo "    WARNING: $cask failed to install; popup will fall back to system fonts."
    fi
  done
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

echo "==> Signing Owlet.app with '$CERT_NAME'"
codesign --sign "$CERT_NAME" --force --deep "$BUILT_APP"
# Verify the signature is valid AND that we used the cert we expected.
# If a stray identity with the same CN exists in the keychain, codesign may
# pick the wrong one — checking Authority here makes that loud, not silent.
codesign --verify --verbose=2 "$BUILT_APP" 2>&1 | sed 's/^/    /'
# Read codesign output FULLY (no early `exit` in awk) — early exit closes the
# pipe and the upstream codesign dies with SIGPIPE, which `set -o pipefail`
# then propagates and `set -e` turns into a silent script exit.
SIGNING_AUTHORITY="$(codesign -dvv "$BUILT_APP" 2>&1 | awk -F'=' '/^Authority/ && !seen {print $2; seen=1}')"
if [ "$SIGNING_AUTHORITY" != "$CERT_NAME" ]; then
  echo "ERROR: app signed with '$SIGNING_AUTHORITY', expected '$CERT_NAME'." >&2
  echo "       Run 'security find-identity -v -p codesigning' to inspect." >&2
  exit 1
fi
echo "    Authority: $SIGNING_AUTHORITY (stable — TCC grants persist across rebuilds)"

echo "==> Installing to $OWLET_INSTALL_DIR/"
mkdir -p "$OWLET_INSTALL_DIR"
rm -rf "$OWLET_INSTALL_DIR/$OWLET_APP_NAME"
cp -R "$BUILT_APP" "$OWLET_INSTALL_DIR/"

# Strip Gatekeeper quarantine so the user doesn't see "developer cannot
# be verified" on first launch. Ad-hoc self-sign means we can't notarize.
xattr -dr com.apple.quarantine "$OWLET_INSTALL_DIR/$OWLET_APP_NAME" 2>/dev/null || true

# Tell Owlet where to find the rewriter binary.
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

# ---------- Migration: ad-hoc -> stable identity ----------
# On the first install with a stable signing identity we MUST tccutil-reset
# the old ad-hoc Owlet entries — the new DR doesn't match the old grant, so
# without a reset the user sees "✓ in Settings, ✗ in app" forever. Once done,
# the sentinel file prevents repeating the reset on subsequent rebuilds.
if [ "$OWLET_NEEDS_MIGRATION" = "1" ]; then
  echo "==> First install with stable identity — resetting TCC for co.greenpassport.owlet"
  # Kill the running ad-hoc-signed Owlet so the newly-signed build relaunches
  # cleanly. Without this `open` would just activate the stale instance.
  pkill -x Owlet >/dev/null 2>&1 || true
  tccutil reset Accessibility co.greenpassport.owlet >/dev/null 2>&1 || true
  tccutil reset ListenEvent co.greenpassport.owlet >/dev/null 2>&1 || true
  touch "$SIGNING_SENTINEL"
fi

# ---------- Launch + open permission panes ----------
OWLET_FRESH_INSTALL=0
if ! pgrep -x "Owlet" >/dev/null 2>&1; then
  OWLET_FRESH_INSTALL=1
fi
# A migration looks like a fresh install for permission flow — both panes
# need to open so the user can re-toggle under the new identity row.
if [ "$OWLET_NEEDS_MIGRATION" = "1" ]; then
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

if [ "$OWLET_NEEDS_MIGRATION" = "1" ]; then
  cat <<'EOF'
NOTE: Migrated from ad-hoc to stable signing identity.

Your prior Accessibility and Input Monitoring grants were tied to the old
ad-hoc signature and have been reset. Both System Settings panes are now
open. Toggle Owlet ON in EACH, then relaunch Owlet from ~/Applications.

After this one re-grant, future `./install.sh` rebuilds KEEP the
permission — no more grant-on-every-build.
EOF
elif [ "$OWLET_FRESH_INSTALL" = "1" ]; then
  cat <<'EOF'
NOTE: First install — Owlet needs TWO macOS permissions:

  • Accessibility    — to read your selection and replace it with the rewrite
  • Input Monitoring — to detect your fn+Ctrl+R hotkey

Both panes are now open. Toggle Owlet ON in EACH, then relaunch
Owlet from ~/Applications. After that, fn+Ctrl+R works in every app.

Owlet will auto-launch on login from now on. The stable signing identity
means you only ever grant these permissions ONCE.
EOF
else
  cat <<'EOF'
Owlet rebuilt and installed at ~/Applications/Owlet.app.

Stable signing identity is in use — your existing Accessibility and Input
Monitoring grants carry over without re-toggling.

If Owlet was already running, the old binary is still in memory. Use
"Restart Owlet" from the menu bar (or quit + relaunch) to pick up the
new build.
EOF
fi
