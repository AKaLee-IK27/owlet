# Owlet Autocomplete — Always-On Inline Prediction (Design)

**Date:** 2026-06-01
**Status:** feat-013 implemented in code; manual verification pending. feat-014..016 pending.
**Feature IDs:** feat-013 (autocomplete core), feat-014 (single-model consolidation + rewriter prompt-hardening), feat-015 (coverage + control), feat-016 (Cotypist extras)

> **Pivot note.** This initiative is sequenced **ahead of** feat-009..012 (rewriter
> dispatcher + event extraction), which are **paused, not deleted**. Per CLAUDE.md
> "one feature at a time," resume feat-009..012 after this lands. Their design doc
> (`2026-05-30-rewriter-dispatcher-and-event-extraction-design.md`) stays valid.

## Goal

A Cotypist-style **always-on inline completion** mode for Owlet. As the user types
in a text field, Owlet reads the text before the caret, asks a tiny local model for
a continuation, and draws it as **grey ghost text at the caret**. **Tab** accepts,
**Esc** or continued typing rejects. On-device, no cloud, never in password fields.
Ships behind a Settings toggle (default **off** until the latency gate passes).

## Why this shape

Proven mechanism (confirmed by two clones that do exactly this — GhostType, and the
open-source Cotabby): **AX reads context + caret rect → tiny model predicts →
click-through overlay window draws ghost text → global event tap catches Tab to
accept.** Owlet already owns the event tap, the AX read, and borderless-panel
rendering. The two **net-new** pieces:

1. Reading the **caret screen-rect** to position the overlay
   (`kAXBoundsForRangeParameterizedAttribute` + `kAXSelectedTextRangeAttribute` —
   Owlet does **not** read these today; it reads `kAXSelectedTextAttribute` value and
   the whole-element `kAXPosition`/`kAXSize` frame only).
2. A **tiny model in a sub-200 ms loop**. `qwen3:8b` over Ollama is 1–5 s (README:
   "first rewrite ~5 s") — far too slow for keystroke latency. Autocomplete *requires*
   a small fast model; the rewriter *tolerates* a slow one. They pull opposite ways.

This is a **new subsystem — more than 8 files plus a latency-critical loop.**
Acknowledged explicitly.

## What's reused vs net-new

| Reused ✅ | Net-new ❌ |
|---|---|
| `HotkeyEventTap.swift` (keystroke/Tab capture) | Tiny model + sub-200 ms loop |
| `AXBridge.swift` read + AX/clipboard write-back | Caret bounds read (`kAXBoundsForRange…`) |
| Borderless-panel patterns (`FloatingButtonController`, `RegionSelectorController`) | Click-through ghost-text overlay at caret |
| `OllamaClient.swift` plumbing, `Preferences`, `SettingsView` | Debounce + per-keystroke request cancellation |

## Component data flow

```
   keystroke
      │
      ▼
 [HotkeyEventTap] ──"text-changed" signal──▶ [AutocompleteController] ◀── debounce/cancel
      │  (swallows Tab/Esc ONLY when a suggestion is visible)        │
      │                                                             │ reads
      │                                          ┌──────────────────┴───────────────┐
      │                                          ▼                                  ▼
      │                                 [AXBridge.readCaretContext]         [Predictor protocol]
      │                                  • text before caret                 • OllamaPredictor (qwen2.5:1.5b)
      │                                  • caret screen-rect                 • (MLXPredictor — fallback impl)
      │                                          │                                  │
      │                                          └──────────────┬───────────────────┘
      │                                                         ▼
      │                                            [GhostTextOverlay] (click-through NSPanel at caret)
      ▼
 Tab ─▶ [AutocompleteController.accept] ─▶ [AXBridge.insertAtCaret] ─▶ overlay.hide
```

Hub-and-spoke, no cycles. `AutocompleteController` is the only stateful brain.

## Model decision (single-model consolidation)

**Decision:** both autocomplete *and* the rewriter default to **`qwen2.5:1.5b`**
(986 MB, Q4_K_M), sharing the Ollama runtime already on the machine — one model file,
no second model to install. `install.sh` pulls only it; `qwen3:8b` is dropped from
new installs.

**Evidence (head-to-head run 2026-06-01, release binary):**

| Input | `qwen3:8b` | `qwen2.5:1.5b` |
|---|---|---|
| Messy prompt → improve | Rich, specific | Correct but flat |
| Draft with URL | **Leaked lowercased mask token, relocated URL** (pre-existing feat-007 bug) | Clean, URL inline |
| Prose tidy-up | Clean | Fine, slightly redundant |
| **Prompt + context** (feat-008) | Rewrote + applied context | ❌ **Ignored both — answered the question** |

**Conclusion:** 1.5B is fine for plain/short rewrites (sometimes cleaner), but on the
**context/Refine flow it abandons "rewrite" and just answers** — a core-feature
regression. This is a guardrail problem (smaller models need firmer instructions),
**not** a model-quality wall. Therefore consolidation is **gated** on a rewriter
prompt-hardening pass + re-test (feat-014). Rip-cord if hardening fails: keep
`qwen3:8b` as the rewriter default (the Settings model picker already allows per-user
choice); autocomplete still uses 1.5B (two models).

## Key decisions

1. **Overlay window, not an input method** — draw ghost text without owning the input pipeline.
2. **Model behind a `Predicting` protocol** — `OllamaPredictor` first (reuses all plumbing, zero new deps). If feat-013's latency gate fails on Ollama, the pre-defined fallback is **MLX Swift** (in-app, no Python/new language), contained by the protocol.
3. **Tab consumed by the tap ONLY while a suggestion is visible** — otherwise Tab must pass through (field nav, indentation). Sharpest correctness risk; dedicated test.
4. **Default off, per-app gating, never in password fields, typed text never logged** — always-on monitoring is a trust surface.
5. **Caret rect via `kAXBoundsForRangeParameterizedAttribute` + `kAXSelectedTextRangeAttribute`** — decides which apps work, and thus Phase-1 app scope (native AppKit fields: TextEdit/Notes/Mail/Safari/Pages).

## Fragile assumption (premise collapse)

This plan assumes a tiny model predicts in ~150 ms end-to-end over Ollama HTTP on the
user's Mac. If it can't, the always-on UX feels laggy/broken — the design survives via
the `Predicting` protocol + MLX fallback, but Phase 1 then grows from "reuse Ollama" to
"add an in-process inference backend." The latency gate tells you which world you're in.

## Risks

| # | Risk | Severity | Mitigation |
|---|------|----------|------------|
| R1 | Tiny model can't hit ~150 ms over Ollama | High | Measured latency gate is feat-013's exit criterion; `Predicting` protocol → MLX fallback |
| R2 | Caret bounds unsupported (Electron/web/terminals) | High | Phase 1 scoped to AX-native fields; Phase 2 degrades gracefully (no mis-positioned overlay) |
| R3 | Tab eaten when no suggestion is showing | High | Consume Tab/Esc only while suggestion visible; dedicated passthrough test |
| R4 | 1.5B answers instead of rewrites (context flow) | Med | feat-014 prompt-hardening + re-test gate; rip-cord = keep 8B for rewrite |
| R5 | Privacy — always-on reads everything typed | Med | Default off; password-field exclusion; never log; per-app deny |
| R6 | TCC re-grant after ad-hoc re-sign | Low | Existing Owlet pain; document re-grant |
| R7 | Battery/CPU of always-on inference | Low | Debounce + cancel in-flight + tiny model + keep-alive |

## Out of scope (recorded)

- Word-by-word Tab, non-AX fallback, typo-fix, emoji-on-`:`, style learning → feat-015/016.
- feat-009..012 dispatcher/event extraction → paused, resume after.
- A 1.5B model is weak at structured JSON; if feat-011/012 resume they may want 8B re-pulled.
