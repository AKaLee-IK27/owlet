# Owlet

Small, friendly local-LLM tools for macOS. **Owlet Rewriter** is a Grammarly-style popup that rewrites the text you've selected into clearer English using Ollama (`qwen2.5:1.5b`). No cloud, no API keys, no browser extension.

> **Status: v0.4 (preview).** The text-rewrite flow is the stable core. Two newer input methods — the hold-Option floating button and double-tap-Shift screenshot rewrite — are implemented and unit-tested but **not yet fully manually verified** across multi-monitor setups. See [Known limitations](#known-limitations).

**Four local writing assists:**

| Trigger | What it does |
| --- | --- |
| `Option+Space` (configurable) | Rewrite the **currently selected text** → inline diff popup → Replace or Copy. |
| **Hold `Option`** (~300 ms) | Pops a floating owl button near the cursor; click it to rewrite the current selection. |
| **Double-tap `Shift`** | Drag-select a screen region → a vision model reads the text in the image → rewrite popup. |
| **Autocomplete** (Settings, default off, **experimental**) | As you type in AX-native text fields, asks a tiny local model for a continuation and shows grey ghost text; **Tab** accepts, **Esc**/typing dismisses. Caret positioning is still being fixed. |

## Prerequisites

- macOS 14+ (tested on macOS 26.5 Apple Silicon)
- [Ollama](https://ollama.com/download)
- [Rust toolchain](https://rustup.rs) — `cargo` is required to build `owlet-rewriter`
- [Homebrew](https://brew.sh) — used to install xcodegen and the brand fonts
- Xcode (full IDE — Command Line Tools alone are not enough)

**Models:** `install.sh` pulls a single model, `qwen2.5:1.5b` (~1 GB), shared by both the text rewriter and autocomplete — no separate download to enable autocomplete. The **vision model used by the double-tap-Shift screenshot rewrite is not pulled automatically** — if you want that feature, run `ollama pull llava:7b` yourself (the default; change it in Settings).

## Install

```bash
cd ~/repos/owlet
./install.sh
```

The installer:

1. Pulls `qwen2.5:1.5b` (~1 GB) via Ollama.
2. Builds the owlet-rewriter Rust binary (`cargo build --release`).
3. Adds `OLLAMA_KEEP_ALIVE=24h` to `~/.zshrc` if not already set.
4. Installs xcodegen if missing.
5. Builds `Owlet.app` (Release), self-signs ad-hoc, copies to `~/Applications/`.
6. Strips Gatekeeper quarantine (`xattr -dr com.apple.quarantine`).
7. Launches Owlet and opens System Settings for both required permissions.

**Manual step (once):** toggle **Owlet** ON in BOTH `Privacy & Security → Accessibility` AND `Privacy & Security → Input Monitoring`, then relaunch Owlet from `/Applications`. macOS doesn't allow scripts to grant TCC permissions. (The screenshot-rewrite feature additionally requests **Screen Recording** the first time you use it.)

## Usage

### Rewrite selected text (the core flow)

1. Select text in any app.
2. Press `Option+Space` (the default hotkey — change it in Settings).
3. Review the inline diff (deleted words in red strikethrough, added words in green).
4. **Enter** to Replace · **Cmd+C** to Copy · **Esc** to Cancel.

In Electron apps (Slack, Discord, VS Code, Notion, Claude desktop) and Chromium browsers, Owlet's AX read returns nothing — the fallback path uses synthetic `Cmd+C`, which works in every app that responds to Cmd+C. Replace in these apps puts the rewrite on the clipboard for manual `Cmd+V`.

### Hold-Option floating button

Press and hold `Option` for ~300 ms (without pressing another key). A small circular owl button appears near the cursor; click it to run the same rewrite on the current selection. Release Option or press any other key to dismiss it.

### Double-tap-Shift screenshot rewrite (preview)

Double-tap `Shift` to open a screen-region selector. Drag to select a region (Esc / right-click / click-without-drag cancels); Owlet captures it, sends the image to a local **vision model** (`llava:7b` by default), and shows the recognised-then-rewritten text in the popup. Requires **Screen Recording** permission (macOS prompts on first use) and the vision model pulled locally (`ollama pull llava:7b`).

### Inline autocomplete (preview, default off)

Open Settings and enable **Autocomplete**. In AX-native text fields, Owlet debounces typing, reads the text before the caret plus the caret bounds, asks `qwen2.5:1.5b` for a short continuation, and draws grey ghost text near the caret. **Tab** accepts the visible suggestion; **Esc** or continued typing dismisses it. Password fields are excluded, and apps that do not expose caret bounds via Accessibility are skipped.

**Known issue (in progress):** the ghost text currently renders at the wrong screen position, away from the caret, even in AX-native fields like TextEdit. Prediction reaches Ollama and the Tab/Esc/dismiss logic is unit-tested, but the caret-bounds-to-screen coordinate mapping is under active debugging, so runtime accept has not been verifiable while the ghost is misplaced. Until that lands, autocomplete is experimental.

## Auto-launch at login

On first successful launch (after permissions are granted) Owlet registers itself as a Login Item via `SMAppService`. You can toggle this in Settings (`Cmd+,`) or in `System Settings → General → Login Items`. If you disable it, Owlet's hotkey works only when you launch the app manually.

## Settings (v0.3 onward)

Press `Cmd+,` (or pick "Settings…" from the menu-bar icon) to change the hotkey, switch the Ollama model, or toggle "Launch at login". The default hotkey is `Option+Space`; intercepting this disables typing a non-breaking space while Owlet is running. If that bites you, change the chord or click "Reset" to restore the default after retrying with something else.

## Customisation

- **Change the model:** open Settings (`Cmd+,`) and pick a locally-pulled Ollama model from the dropdown. No rebuild required.
- **Change the hotkey:** open Settings (`Cmd+,`), click Record, press your preferred chord. Changes take effect immediately.
- **Change the prompt:** edit `const SYSTEM_PROMPT` in `tools/rewriter/src/main.rs`, then re-run `./install.sh`. The shipped default is tuned for **improving prompts** written for a chat AI (Claude / GPT / Gemini) — that's also why the popup is titled "Improve prompt". Swap in your own prompt for general rewriting.
- **Add context to a rewrite:** in the result popup, click **Add context**, type a note (e.g. "for my boss", "keep it under two sentences"), and press **Refine** to re-run the rewrite with that guidance (feat-008). URLs and email addresses in the draft are preserved verbatim (feat-007).
- **Change the vision model:** open Settings (`Cmd+,`) and pick a locally-pulled vision-capable model for the screenshot flow (default `llava:7b`).
- **Enable autocomplete:** open Settings (`Cmd+,`), turn on **Autocomplete**, and pick a locally-pulled autocomplete model (default `qwen2.5:1.5b`).

## Known limitations

- **Screenshot rewrite is preview-quality.** feat-006 (double-tap Shift) is implemented and unit-tested, but the end-to-end path — region selection on a *secondary* display, and the captured PNG resolving to the correct region at full Retina resolution — has not been fully verified by hand on a multi-monitor setup. Treat it as preview.
- **Deprecated capture API.** `ScreenshotCapturer` uses `CGDisplayCreateImage`, which is obsoleted in the macOS 15 SDK (it compiles/runs today only against an older SDK). A migration to `SCScreenshotManager` (ScreenCaptureKit) is tracked as a follow-up.
- **Only the "Add context" mode is wired.** v0.4 ships the **Add context** chip (feat-008), which re-runs the rewrite with a free-text note. The other preset modes (Clarify / Structured / Examples / Compact) are not yet implemented — the rewriter has no `--mode` flag — so they're hidden for now; the `ImproveMode` scaffolding remains for that future work.
- **Autocomplete is experimental and default-off.** The prediction loop and Tab/Esc handling are unit-tested, but the ghost text currently renders at the wrong screen position (away from the caret) even in AX-native fields; the caret-bounds-to-screen coordinate mapping is being debugged. It also still needs manual latency and supported-app verification. Phase 1 only targets AX-native fields that expose `kAXBoundsForRangeParameterizedAttribute`; Electron apps, terminals, and other non-cooperative fields skip suggestions.
- **Brand fonts degrade silently.** Fraunces and Be Vietnam Pro are installed by `install.sh` via Homebrew casks. If they're missing, the popup falls back to the system font (SF Pro) with no runtime warning.

## Project layout

```
~/repos/owlet/
├── tools/rewriter/      # Rust CLI (Ollama backend, build with `cargo build --release`)
├── Owlet/               # SwiftUI app (Xcode project, generated by xcodegen)
├── docs/superpowers/    # specs + plans
├── install.sh           # one-shot installer / refresh script
└── README.md
```

## Manual smoke test checklist

After install:

- [ ] **TextEdit** — type a draft, select, `Option+Space`. Popup with inline diff → Enter → text replaced in place.
- [ ] **Claude desktop** (Electron) — same flow → popup → Replace puts rewrite on clipboard for `Cmd+V`.
- [ ] **Chrome / Safari article body** — same as Claude.
- [ ] **Slack / Discord / Notion / VS Code** — same.
- [ ] **Terminal / iTerm / Ghostty** — same.
- [ ] **Empty selection** — popup shows "Select some text first".
- [ ] **Password field** — popup shows "Owlet won't read from password fields".
- [ ] **URL preservation** — rewrite a draft containing a URL (e.g. `https://example.com/a_b?x=1`). Confirm the URL appears in the result byte-for-byte, in place (not relocated to a trailing block).
- [ ] **Add context / Refine** — after a rewrite, click **Add context**, type a note (e.g. "make it formal"), press **Refine**. Confirm the field accepts keystrokes (the popup takes key focus), the rewrite re-runs with the note applied, **Replace** still works, and clicking outside still dismisses (typing does **not** dismiss). The chip should **not** appear on screenshot-rewrite results.
- [ ] **Spam `Option+Space` rapidly** — only one popup, in-flight cancelled.
- [ ] **Kill Owlet** via Activity Monitor → press hotkey → nothing (expected).
- [ ] **Reboot** → Owlet auto-launches → hotkey works.

**Hold-Option floating button (v0.4):**
- [ ] In any text field, hold `Option` ~300 ms without another key → owl button appears near the cursor.
- [ ] Click it → rewrite popup appears for the current selection.
- [ ] Release Option / press another key → button dismisses without firing.

**Double-tap-Shift screenshot rewrite (v0.4, preview):**
- [ ] Double-tap `Shift` → region-selector overlay; only the cursor's screen dims.
- [ ] Drag a region → popup shows "Analyzing screenshot…" then the rewritten text.
- [ ] `Esc` / right-click / click-without-drag cancels; double-tap again toggles the overlay closed.
- [ ] **Multi-monitor:** drag-select on the *secondary* screen; moving the cursor across screens moves the dim. Open the captured PNG and confirm it's the right region at full resolution.
- [ ] Grant **Screen Recording** when prompted on first use; confirm `llava:7b` (or your chosen vision model) is pulled.

**Inline autocomplete (experimental — caret positioning currently fails):**
- [ ] Pull the default model if needed: `ollama pull qwen2.5:1.5b`.
- [ ] Settings → enable **Autocomplete**. TextEdit: type in a normal text field → grey ghost text appears. **Known-failing:** it currently lands away from the caret, not next to it (coordinate-mapping bug under debug).
- [ ] Press **Tab** while a suggestion is visible → suggestion inserts at the caret.
- [ ] Press **Tab** with no suggestion visible → normal tab/indent behavior passes through.
- [ ] Press **Esc** or keep typing → suggestion dismisses.
- [ ] Password field → no suggestion appears.
- [ ] Measure p50 end-to-end latency; target ≤ ~200 ms. Notes / Mail / Safari / Pages: record which expose caret bounds and position correctly.

**Settings window (v0.3):**
- [ ] Open via `Cmd+,` or menubar → "Settings…". Hotkey shows `⌥ Space`; autocomplete controls are visible and default off.
- [ ] Click `Record`, press `Ctrl+Shift+J`. The chord is committed on capture (no extra Save click); the field now shows `⌃⇧J`. Trigger a rewrite with the new chord — popup appears.
- [ ] Press `Option+Space` in a text field — it types a non-breaking space (NBSP), confirming the old binding is released.
- [ ] Click `Reset`. Trigger with `Option+Space`; popup appears.
- [ ] Switch the model picker to a different locally-pulled model. Trigger a rewrite. In `Console.app` (filter `subsystem:co.greenpassport.owlet`), verify the spawned `owlet-rewriter` was invoked with the new `--model` value.
- [ ] Toggle "Launch at login" off, relaunch the Mac (or run `osascript -e 'tell application "Owlet" to quit'`), confirm Owlet doesn't auto-start. Re-toggle on, confirm it does.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Hotkey doesn't fire | Check Owlet is running (Activity Monitor). Verify Accessibility AND Input Monitoring are both ON in System Settings. |
| Permission revoked surprise alert | A required permission was disabled in System Settings. Re-toggle and relaunch Owlet. |
| Owlet quit on first launch | Permission modal expected Quit — you need to grant permissions in System Settings then relaunch from `/Applications`. |
| First rewrite takes ~5 s | Model cold-start. `OLLAMA_KEEP_ALIVE=24h` keeps it warm. |
| "Looks like Ollama isn't running" | `ollama serve` in another terminal. |
| Replace does nothing in some apps | Apps without AX text-write support fall back to clipboard. Press `Cmd+V` to paste manually. |

## Upgrading from v0.1

v0.2 removes the Hammerspoon dependency. Re-running `install.sh` will:
- Strip the `prompt-rewriter:hotkey` block from `~/.hammerspoon/init.lua` (other Lua content is preserved).
- Build and install the new self-contained `Owlet.app`.

The new Owlet.app's ad-hoc signature is different from v0.1's, so macOS invalidates the existing Accessibility grant. You'll need to re-grant Accessibility AND grant Input Monitoring (new in v0.2) before the hotkey works again.

Hammerspoon itself is left installed if you had it. It's no longer required.

## Why "Owlet"?

A friendly small owl — inspired by the Pokémon Rowlet. The "-let" suffix reads as "small thing", matching the toolkit's spirit.
