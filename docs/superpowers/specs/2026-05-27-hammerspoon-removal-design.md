# Owlet — Hammerspoon Removal Design Spec (v0.2)

**Date:** 2026-05-27
**Status:** Draft, pending user approval
**Scope:** Make Owlet a fully self-contained macOS app. Drop the Hammerspoon dependency entirely. Owlet owns the global `fn+Ctrl+R` hotkey via its own `CGEventTap`, performs the Cmd+C clipboard capture in Swift, registers itself as a login item via `SMAppService`, and ships a single combined permission flow for Accessibility + Input Monitoring on first launch.

This spec is the successor to `2026-05-27-popup-ui-design.md` (v0.1). It does not change the popup UX or the rewrite pipeline; it changes who owns the hotkey and capture layer.

## 1. Decisions locked in

| # | Decision | Rationale |
|---|---|---|
| 1 | **Full Hammerspoon removal.** install.sh no longer installs Hammerspoon. install.sh strips the `prompt-rewriter:hotkey` block from `~/.hammerspoon/init.lua` on upgrade (preserves any other Lua code). README/docs lose Hammerspoon mentions. | "Owlet — small useful tools for Mac users" can't reasonably require a heavyweight automation framework as a precondition. One app, one install. |
| 2 | **Silent auto-start via `SMAppService.mainApp`.** Owlet registers itself as a Login Item the first time it launches successfully (after all permissions are granted). User can disable via System Settings → General → Login Items. | Matches Raycast / Hazel / Bartender. Hotkey-driven helpers must be running to be useful. |
| 3 | **One combined permission modal on first launch** explaining Accessibility AND Input Monitoring, with one deep-link button per pane. App quits if either is missing. | Lower cognitive load than sequential modals. User sees the full ask upfront. |
| 4 | **Hardcoded `fn+Ctrl+R` chord for v0.2.** Configuration UI deferred. | YAGNI — no user has asked for a custom hotkey yet. Adding it is a v0.3 feature. |
| 5 | **Big-bang migration in one PR.** Not staged. Hammerspoon stays in place until merge, then disappears entirely. | The user wants the migration "in this version" — minimum incremental complexity, single review surface. |

## 2. Architecture

```
                ┌──────────────────────────────────────────┐
   fn+Ctrl+R    │              Owlet.app                   │
   ┌──────────▶│  (SwiftUI menu bar helper, LSUIElement,  │
   │   global  │   self-signed, autostarted by SMAppService) │
   │   event   │                                          │
   │   tap     │  HotkeyEventTap ─► CaptureFlow ─► Popup  │
   │           │      │                  │                │
   │           │      ▼                  ▼                │
   │           │  Capture handler   tools/rewriter/        │
   │           │  (Cmd+C in Swift)  rewrite_prompt.py      │
   │           │                    (Python CLI ─► Ollama)│
   │           └──────────────────────┬───────────────────┘
   │                                  │
   │                          ApplicationServices
   │                          (AX read/write)
   │                                  │
   └──────────────────────────────────┴── source app's selected text
```

Compared to v0.1:
- **Removed:** Hammerspoon, the `~/.hammerspoon/init.lua` `prompt-rewriter:hotkey` block, the `owlet://` URL scheme (no longer needed — Owlet's own event tap fires the flow directly).
- **Added:** `HotkeyEventTap` (Swift CGEventTap), `LoginItemManager` (SMAppService), `PermissionChecker` (AX + IM checks + combined modal).
- **Kept:** Popup UI, RewriterFlow state machine, OllamaClient subprocess, AXBridge for selection capture + replacement, Python CLI.

## 3. New components

| Component | Responsibility | Touches |
|---|---|---|
| `HotkeyEventTap.swift` (NEW) | `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: keyDown mask, callback: ...)`. Callback matches the chord (`keyCode = "r"`, `flags.fn`, `flags.ctrl`, none of `cmd/alt/shift`). On match: enqueues capture work to a background `DispatchQueue` and returns `nil` (event consumed). Self-heals if tap is disabled by either `kCGEventTapDisabledByTimeout` or `kCGEventTapDisabledByUserInput`. | CoreGraphics, ApplicationServices |
| `LoginItemManager.swift` (NEW) | Wraps `SMAppService.mainApp`. `registerIfNeeded()` registers Owlet (no-op if already registered). `unregister()` exposed for future settings UI but not called in v0.2. Checks `status` to avoid double-register attempts. | ServiceManagement |
| `PermissionChecker.swift` (NEW) | `checkAccessibility() -> Bool` via `AXIsProcessTrusted()`. `checkInputMonitoring() -> Bool` via `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` (requires `import IOKit.hid`). Returns `enum PermissionStatus { case allGranted, missing(Set<Permission>) }`. | IOKit.hid, ApplicationServices |
| `PermissionModal.swift` (NEW SwiftUI view) | One-window modal driven by `PermissionStatus.missing(perms)`. Shows usage description per missing permission and deep-link buttons. `Open Accessibility…` → `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`. `Open Input Monitoring…` → `x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent`. `Quit` button terminates app. | SwiftUI, NSWorkspace |

### Changed components

| Component | Change |
|---|---|
| `OwletApp.swift` | `applicationDidFinishLaunching`: run `PermissionChecker.check()`. If missing → show `PermissionModal` window + return (app stays alive for the modal). On modal's Quit → `NSApp.terminate(nil)`. If all granted → start `HotkeyEventTap`, call `LoginItemManager.registerIfNeeded()`. **Remove** the `NSAppleEventManager` URL handler — no more `owlet://` URLs. **Remove** the `HotkeyCoordinator` debounce indirection — the event tap callback talks straight to `CaptureFlow`. |
| `AXBridge.swift` | Replace the previous `clipboardRoundtripCopy()` (removed in the Hammerspoon-side capture refactor) with `swiftCmdCCapture()`. Implements: poll for `fn+ctrl` release (300 ms cap), post Cmd+C with explicit `setFlags({cmd=true})` on the `CGEvent`, poll `NSPasteboard.changeCount` up to 1 second, read clipboard. Restore prior clipboard after a 5-second deferred block (long enough for popup to read and the user to act). Mirrors the Lua fix we applied in Hammerspoon. |
| `RewriterFlow.swift` | No behavioural change. The flow is started from the new HotkeyEventTap (was: from URL handler). Same `start()` method, same state transitions. |
| `Info.plist` | Add `NSInputMonitoringUsageDescription` (the IM grant). Keep `NSAccessibilityUsageDescription`. **Remove** `CFBundleURLTypes` entry for `owlet://` (no longer needed). Keep `LSUIElement: YES`. |
| `Owlet.entitlements` | Sandbox stays disabled. Outbound network stays enabled. No new entitlements required. |
| `install.sh` | See section 5. |

## 4. First-launch flow

```
Owlet.app launched
  │
  ▼
  PermissionChecker.check()
  │
  ├── .allGranted ──► HotkeyEventTap.start()
  │                   LoginItemManager.registerIfNeeded()
  │                   App idle in menu bar, hotkey live
  │
  └── .missing(let perms) ──► PermissionModal:
       ┌──────────────────────────────────────────┐
       │ Owlet needs two macOS permissions:       │
       │                                          │
       │ • Accessibility                          │
       │   To read the text you've selected and   │
       │   replace it with the rewrite.           │
       │                                          │
       │ • Input Monitoring                       │
       │   To detect your fn+Ctrl+R hotkey.       │
       │                                          │
       │   [Open Accessibility…]                  │
       │   [Open Input Monitoring…]               │
       │   [Quit]                                 │
       └──────────────────────────────────────────┘
       (Each button is hidden if that permission is already granted.)
       (Pressing Quit terminates Owlet. User must relaunch after granting.)
```

Note: macOS does not deliver permission-grant callbacks back to the running app; the user must quit Owlet and relaunch for the new TCC state to take effect. The modal explicitly says "Quit and relaunch after granting."

## 5. install.sh changes

| Section | v0.1 behaviour | v0.2 behaviour |
|---|---|---|
| Ollama check + pull | unchanged | unchanged |
| Python venv at `tools/rewriter/.venv/` | unchanged | unchanged |
| `OLLAMA_KEEP_ALIVE=24h` to `~/.zshrc` | unchanged | unchanged |
| Hammerspoon brew install | `brew install --cask hammerspoon` if missing | **Removed entirely** |
| Hammerspoon init.lua block | awk-refresh the `prompt-rewriter:hotkey` block | **awk-STRIP the block** if present, leaving any other Lua in init.lua intact. Skip entirely if init.lua doesn't exist. If init.lua exists but stripping leaves it empty, leave the empty file in place (don't delete — Hammerspoon expects to find init.lua even if empty, and the user may add content later). |
| Hammerspoon reload via osascript | `osascript -e 'tell application "Hammerspoon" to execute lua code "hs.reload()"'` | **Removed entirely** |
| xcodebuild + codesign | unchanged | unchanged |
| Copy to `~/Applications/Owlet.app` | unchanged | unchanged + **NEW**: `xattr -dr com.apple.quarantine ~/Applications/Owlet.app` immediately after copy (prevents Gatekeeper "developer cannot be verified" prompt on first launch). |
| `defaults write rewriterDirectory` | unchanged | unchanged |
| `lsregister -R -f -trusted` | unchanged | unchanged |
| `open ~/Applications/Owlet.app` | unchanged | unchanged |
| Open System Settings → Accessibility on fresh install | unchanged | **Replace with:** open BOTH panes — Accessibility AND Input Monitoring — on fresh install. Two `open x-apple.systempreferences:...` calls. |
| Trailing message | "Toggle Hammerspoon ON in Accessibility…" | "Toggle Owlet ON in BOTH Accessibility AND Input Monitoring, then relaunch Owlet from /Applications." |

### Diagnostic block cleanup

The `owlet-diag:hotkey` block in `~/.hammerspoon/init.lua` from the prior debug session is also stripped by install.sh on upgrade. It was a Hammerspoon-only debug aid; with Hammerspoon out of the loop, it can't help.

## 6. Edge cases and failure modes

| Failure | Behaviour |
|---|---|
| **Event tap callback runs synchronously** in the system run loop. Heavy work blocks it; macOS may disable the tap with `kCGEventTapDisabledByTimeout`. | Callback enqueues `CaptureFlow.start()` to `DispatchQueue.global(qos: .userInitiated)` and returns `nil` (consume event) immediately. The callback itself does only the chord-match check. |
| **Event tap disabled by timeout** (`kCGEventTapDisabledByTimeout`) | Callback detects the disable event type and calls `CGEvent.tapEnable(tap: ourTap, enable: true)` to re-enable. Log once via `os_log`. |
| **Event tap disabled by user input** (`kCGEventTapDisabledByUserInput`) | Same re-enable path. Less common but documented. |
| **Event tap creation fails at launch** (returns nil) | Most likely cause: Input Monitoring not granted. PermissionChecker should have caught this before — but if the check is a false positive, `HotkeyEventTap.start()` returns an error which OwletApp surfaces in a fallback modal: "Owlet couldn't register the hotkey. Re-check Input Monitoring in System Settings." |
| **User holds the chord longer than 300 ms** so our wait-for-release loop times out | Post Cmd+C anyway. Likely produces the 4-modifier bug we already diagnosed — the source app's Copy handler doesn't fire — and `swiftCmdCCapture()` returns nil → popup shows "Select some text first." Acceptable v0.2 behaviour (rare). |
| **User releases fn but not ctrl** (or vice versa) | Wait-for-release loop checks BOTH must be `false` to break. Stays in the loop, ticking every 10 ms, up to the 300 ms cap. |
| **Caps Lock toggled when chord fires** | Caps Lock state is ignored by our chord matcher. Hotkey fires regardless. (Caps Lock is a separate flag from cmd/alt/ctrl/shift/fn — we filter only the latter five.) |
| **User has fn+Ctrl+R bound to another system shortcut** | First event tap to consume wins. If Owlet's tap is at `.headInsertEventTap`, we win. If another app has installed a tap before us, they may see it first. Document as a known interaction in README. |
| **Source app doesn't respond to Cmd+C** (read-only display, custom keymap) | Clipboard `changeCount` doesn't advance within the 1 s timeout. `swiftCmdCCapture()` returns nil. Popup shows "Select some text first." Same as v0.1 fallback path. |
| **Source app responds to Cmd+C with non-text data** (image, file path) | `NSPasteboard.general.string(forType: .string)` returns nil. Treated as empty. |
| **Permission revoked AFTER first successful launch** | Event tap silently stops firing. To surface this: a `Timer` schedules `PermissionChecker.check()` every 60 seconds in the background. On a state change (granted → missing), post an `NSUserNotification`: "Owlet stopped working — permission revoked. Re-grant and relaunch." Polling at 60 s is light enough; revocation is rare. |
| **Owlet not running** (user killed it via Activity Monitor; or it crashed) | Hotkey is dead until next launch. No fallback in v0.2. Documented in README. User can re-launch from /Applications, or reboot (login item auto-launches). |
| **SMAppService.register() fails** because Owlet is launched from a non-standard location (e.g. directly from build output) | `LoginItemManager.registerIfNeeded()` logs the failure via `os_log` but does not block app launch. Hotkey still works for the session; just won't survive reboot. |
| **Multiple Owlet.app copies on disk** (DerivedData, build/, ~/Applications) | install.sh deletes `~/repos/owlet/Owlet/build/` after install (cleanup left over from build). lsregister already favours ~/Applications. We learned this lesson in v0.1 — same hygiene applies. |
| **Gatekeeper quarantine** on fresh-clone install | install.sh's new `xattr -dr com.apple.quarantine ~/Applications/Owlet.app` strips the attribute. No first-launch prompt. |
| **TCC re-grant on every install.sh re-run** | Ad-hoc codesign means CDHash changes every build → TCC invalidates. User must re-grant both permissions after each install.sh. Documented as v0.2 friction. **v0.3 follow-up:** adopt a stable self-signed cert from the user's Keychain so the signature identity persists across rebuilds. |
| **Existing v0.1 user upgrades** | install.sh strips Hammerspoon block from init.lua (preserving other Lua), unregisters old URL scheme handler (lsregister), installs new Owlet.app. User must grant Input Monitoring (new). Existing AX grant persists IF the new build's signature happens to match — usually it doesn't (CDHash differs), so both grants needed again. Documented in upgrade notes. |

## 7. Permissions surface

| Permission | v0.1 | v0.2 | Why |
|---|---|---|---|
| Accessibility | Hammerspoon + Owlet | Owlet only | Read AXSelectedText, post Cmd+C / Cmd+V synthetic events, write replacement text |
| Input Monitoring | Hammerspoon | **Owlet only (new)** | Receive global keyDown events via CGEventTap |
| Automation (AppleScript) | Hammerspoon (`hs.allowAppleScript`) | Not needed | Was only used so install.sh could `hs.reload()` Hammerspoon. |
| Network (outbound) | Owlet | Owlet | HTTP to localhost:11434 for Ollama |

Net result: **one fewer app holds keyboard-event-reading capability** on the user's system (Hammerspoon is removed); **the remaining app (Owlet) holds the same set of permissions Hammerspoon used to** (AX + IM). Net change in trust surface area: roughly neutral but consolidated to one app.

## 8. Testing strategy

### Swift unit tests
- `PermissionChecker.check()` with mocked `AXIsProcessTrusted` and `IOHIDCheckAccess` — all 4 permutations of (AX, IM) ∈ {granted, denied}.
- Chord-matching pure function (extracted from `HotkeyEventTap` callback): table-driven with rows for `(keyCode, flags) → expected match` covering: exact chord, missing fn, missing ctrl, extra cmd, extra shift, wrong key.
- `LoginItemManager` decision logic (whether to call `register()` based on `SMAppService.status`).
- `AXBridge.swiftCmdCCapture()` — covered by mocked `NSPasteboard` + `CGEvent.post` (test via protocol seam).

### Swift integration tests
- Existing `RewriterFlowTests` migrated: `start()` is now invoked directly (no URL parsing); same mocked `AXBridging` + `Rewriting`.
- New: `OwletAppLaunch` test that exercises the launch decision tree (mocked `PermissionChecker`) — covers all four permission combinations.

### Manual smoke tests (post-build)
- TextEdit → fn+Ctrl+R → AX-path Replace works.
- Claude desktop → fn+Ctrl+R → Cmd+C path → popup with rewrite → Replace falls back to clipboard.
- Chrome → fn+Ctrl+R → Cmd+C path → popup with rewrite.
- Slack / Discord (any Electron app you use) → same.
- Terminal → fn+Ctrl+R with selection → same.
- VS Code → same.
- Kill Owlet via Activity Monitor → press fn+Ctrl+R → nothing happens (expected).
- Reboot → Owlet auto-launches (login item) → fn+Ctrl+R works.
- Revoke Accessibility in System Settings → wait 60 s → notification appears.
- Upgrade smoke: start from clean v0.1 install with Hammerspoon block, run new install.sh, verify the block is stripped and Hammerspoon's other lua content (if any) is preserved.

## 9. File layout (post-migration)

```
~/repos/owlet/
├── README.md                    ← rewritten: no Hammerspoon mentions
├── install.sh                   ← Hammerspoon section removed; xattr strip added
├── .gitignore                   ← unchanged
│
├── docs/superpowers/
│   ├── specs/
│   │   ├── 2026-05-27-popup-ui-design.md         (v0.1, kept for history)
│   │   └── 2026-05-27-hammerspoon-removal-design.md   ← this file
│   └── plans/
│       └── 2026-05-27-hammerspoon-removal.md     ← (next step)
│
├── tools/rewriter/              ← unchanged
│
└── Owlet/
    ├── project.yml              ← Info.plist additions, URL scheme removed
    ├── Owlet/
    │   ├── OwletApp.swift                ← URL handler removed, launch tree rewired
    │   ├── HotkeyEventTap.swift          ← NEW
    │   ├── LoginItemManager.swift        ← NEW
    │   ├── PermissionChecker.swift       ← NEW
    │   ├── AXBridge.swift                ← swiftCmdCCapture() added
    │   ├── RewriterFlow.swift            ← unchanged behaviour, called from new path
    │   ├── CommandDispatcher.swift       ← REMOVED (no more URL verbs in v0.2)
    │   ├── UnavailableFlow.swift         ← REMOVED (only existed for unknown verbs)
    │   ├── URLSchemeParser.swift         ← REMOVED (URL scheme dropped)
    │   ├── HotkeyCoordinator.swift       ← REMOVED (debounce moves into HotkeyEventTap if needed)
    │   ├── … (all other files unchanged)
    │   └── Views/
    │       └── PermissionModal.swift     ← NEW
    └── OwletTests/
        ├── PermissionCheckerTests.swift  ← NEW
        ├── ChordMatcherTests.swift       ← NEW
        ├── LoginItemManagerTests.swift   ← NEW
        ├── URLSchemeTests.swift          ← REMOVED (URL scheme dropped)
        ├── CommandDispatcherTests.swift  ← REMOVED
        ├── HotkeyCoordinatorTests.swift  ← REMOVED (if HotkeyCoordinator is removed)
        └── … (existing diff/clean/popup/rewriter tests unchanged)
```

## 10. Out of scope for v0.2

- **Configurable hotkey** (settings UI). Hardcoded `fn+Ctrl+R`. A user-config plist is one of the obvious follow-ups but not required to ship the migration.
- **Menu bar status icon.** Owlet stays invisible (LSUIElement, no NSStatusItem). When permission is revoked the user only finds out via the polling notification. A status item is a clear v0.3 candidate.
- **Notarization / Developer ID signing.** Ad-hoc continues; `xattr -dr com.apple.quarantine` makes first-launch work.
- **Stable signing identity from Keychain.** Without this, every install.sh rebuild invalidates TCC. Documented as v0.3 follow-up.
- **Translator / Grammar commands.** `owlet://translate` and `owlet://grammar` were reserved as URL routes in v0.1; the URL scheme is gone in v0.2. Future commands will need their own hotkey + flow class — design open.
- **Visual status indicator for the in-flight rewrite.** Popup loading view is enough.

## 11. Open risks

- **Input Monitoring is a strong trust grant** — Owlet can observe every keyboard event system-wide. The chord matcher filters aggressively (only matches the exact chord) and the tap is `.headInsertEventTap` (other taps still see the same events), but the capability itself is broad. Acceptable for a personal tool; would need a different posture for distribution to less-technical users.
- **Polling for permission revocation is best-effort.** A 60 s window means the user can experience up to a minute of "hotkey doesn't work, no feedback" if they revoke permission. Improvement: a menu bar status item would let us reflect state instantly.
- **CGEventTap reliability on macOS 26.5.** Apple periodically tightens event-tap behaviour. The self-healing on `disabledBy*` events should handle the known modes, but a future macOS release could break the model entirely. Mitigation: keep the Hammerspoon fallback documented in git history so we can re-introduce it if needed.
- **Login item registration prompts.** macOS Sonoma+ shows a system notification when an app registers a login item — "Owlet has added a login item". Some users may find this surprising even though it's the documented behaviour. Acceptable trade-off for the silent-auto-start choice.

## 12. Next step

Invoke `superpowers:writing-plans` to produce a step-by-step implementation plan. The plan will cover, in build order:
1. Information architecture cleanup (remove URL-scheme components: URLSchemeParser, CommandDispatcher, UnavailableFlow, HotkeyCoordinator; remove URL scheme from Info.plist via `project.yml`).
2. `PermissionChecker.swift` + tests (pure Swift, easy TDD).
3. `LoginItemManager.swift` + tests.
4. `HotkeyEventTap.swift` (CGEvent integration, hardest unit-test; chord-matcher extracted as pure function with TDD coverage).
5. `AXBridge.swiftCmdCCapture()` — Swift port of the Lua capture logic with modifier-release + explicit flags.
6. `PermissionModal.swift` SwiftUI view.
7. `OwletApp.swift` rewire: launch tree, hotkey wiring, login item registration.
8. `Info.plist` updates: add `NSInputMonitoringUsageDescription`, remove `CFBundleURLTypes` (via `project.yml`).
9. `install.sh`: strip Hammerspoon sections, add awk-strip of init.lua block, add `xattr` quarantine strip, open both permission panes on fresh install.
10. README rewrite (remove Hammerspoon mentions).
11. Full smoke test pass including upgrade-from-v0.1 path.
12. Tag v0.2.0.

No code is written until the plan is also approved.
