# Rewriter Options v0.4 Design

**Date:** 2026-05-29
**Status:** Draft
**Feature IDs:** feat-007 (URL/email preservation), feat-008 (per-rewrite context)

## Overview

Two enhancements to the rewriter, both living at the prompt-construction layer
(`tools/rewriter/src/main.rs` + the Swift `RewriterFlow` → `OllamaClient` path):

1. **feat-007 — URL & email preservation.** URLs and emails in the draft survive
   the rewrite byte-for-byte instead of being mangled, "fixed", or dropped by the
   model. Implemented entirely in the Rust rewriter via placeholder masking.
2. **feat-008 — Per-rewrite context.** The user can re-run a rewrite with a
   free-text note ("this is for my boss", "keep it under two sentences"). The
   note is opt-in and never alters the instant first rewrite.

Both are additive. The existing instant text rewrite, the hold-Option floating
button, and the double-tap-Shift screenshot flow are unchanged.

**Ship order: feat-007 first.** It is Rust-only, fully unit-testable without a
model or UI, and carries none of feat-008's macOS window-focus risk. feat-008
ships second, on top of it. Per `CLAUDE.md`, they are implemented one at a time;
this single spec defines both and produces two `feature_list.json` entries.

---

# feat-007 — URL & email preservation

## Problem

The system prompt orders *substantive structural* rewriting (`main.rs:29`). A
model rewriting structure will happily reformat, "correct", or drop a URL — e.g.
turn `https://ex.com/a_b` into `https://ex.com/a-b`, strip a tracking query, or
delete the sentence the link lived in. A prompt instruction ("don't change
URLs") is unreliable and untestable. We want a deterministic guarantee.

## Mechanism — placeholder masking

Established localization/MT technique: extract protected spans, replace with
opaque tokens, run the model, restore the originals.

1. Read the stdin draft.
2. Use the **`linkify`** crate (`LinkFinder` with `LinkKind::Url` **and**
   `LinkKind::Email`) to find link spans. linkify handles trailing punctuation
   and parentheses correctly — the well-known regex pitfalls — so we do not roll
   our own URL regex.
3. Replace each span, left to right, with an **ASCII sentinel token** of the form
   `OWLETLINKZ0Z`, `OWLETLINKZ1Z`, … (a `Z`-delimited index). Keep an ordered
   `Vec<String>` mapping index → original span. Two constraints drive the token
   shape:
   - **ASCII, not private-use-area codepoints** — PUA chars are frequently mapped
     to UNK by tokenizers and then dropped by the model.
   - **No markdown-significant characters** (`_`, `*`, `` ` ``, `[`, `]`, `#`,
     `~`). In particular avoid the obvious `__OWLET_LINK_0__` form: `__text__` is
     CommonMark **strong emphasis**, and a model emitting prompt text (destined
     for other chat AIs) may normalize it to `**…**` or strip it — which breaks
     the `(\d+)` restore match and bounces the URL to the re-append path. Plain
     uppercase letters + digits sidestep this.
   - **Collision guard:** if the raw draft already contains the substring
     `OWLETLINKZ`, bump the prefix (e.g. `OWLET2LINKZ`) until it does not occur
     in the input. (Vanishingly rare; cheap to check.)
4. Send the **masked** text to Ollama.
5. `clean_output` (existing `<think>`/quote stripping) runs on the raw response.
6. **Restore** on the cleaned text using a tolerant regex `OWLETLINKZ(\d+)Z`
   (not literal `replace`): capture the index and swap in `mapping[index]`. Regex
   tolerance means a minor adjacent-text shift around the token still restores in
   place; only a genuinely absent token counts as "dropped".

### Emails are in scope

linkify matches emails as well as URLs, and the same rationale applies (a
reworded address is a broken address). Both `Url` and `Email` kinds are masked.

### Dropped-token policy: re-append (deduped, label-free)

If a token index from the mapping never appears in the restored output, the
model dropped that link during restructuring. Policy:

- **Re-append the dropped original(s)**, in mapping order, after the rewritten
  text (separated by a single blank line, each on its own line).
- **No header label.** A hardcoded "Links:" string would violate the rewriter's
  language-preservation contract (`main.rs:31–37`) for non-English drafts. Append
  the bare URL/email only.
- **Dedupe against the output.** Before appending, check the restored output does
  not already literally contain that exact link string; only append genuinely
  absent ones. (Rationale: the model only ever sees the token, never the literal
  URL, so it cannot reproduce a URL in prose — the *only* case this guard handles
  is the **same URL appearing multiple times** in the input, i.e. N tokens where
  some were kept and some dropped; don't append a copy already restored from a
  kept token.) If a user genuinely repeated a URL and one instance dropped, dedupe
  leaves a single copy — a deliberate, acceptable simplification.

This keeps the improved rewrite while guaranteeing no link is silently lost — the
one outcome the feature exists to prevent.

### Known trade-off

Masking hides the URL's content (slug, query) from the model, so a rewrite that
*depended* on reading the URL (rare for prompt drafts) loses that signal. Accepted:
verbatim preservation is the stated goal and dominates.

## Architecture (feat-007)

### Modified files

| File | Change |
|------|--------|
| `tools/rewriter/Cargo.toml` | Add `linkify` dependency (pinned). |
| `tools/rewriter/src/main.rs` | Add `mask_links()`, `restore_links()`, `append_dropped()`; thread them through `run()`. |

`run()` flow becomes:

```text
read stdin → (masked, mapping) = mask_links(input)
           → raw = call_ollama(masked, model, context?)
           → cleaned = clean_output(raw)
           → restored = restore_links(cleaned, &mapping)
           → final = append_dropped(restored, &mapping)   // deduped, label-free
           → emit final
```

No-link input ⇒ `mapping` empty ⇒ all three functions are no-ops ⇒ today's exact
behavior and output.

### Function contracts

```rust
/// Returns the masked text and the ordered index→original mapping.
fn mask_links(input: &str) -> (String, Vec<String>);

/// Replaces every `OWLETLINKZ<n>Z` with mapping[n] (tolerant regex).
fn restore_links(text: &str, mapping: &[String]) -> String;

/// Appends, label-free, any mapping entry not already present in `text`.
fn append_dropped(text: &str, mapping: &[String]) -> String;
```

## Testing (feat-007) — no model required

- `mask_links` finds and replaces a URL; an email; multiple links; preserves order.
- linkify trailing-punctuation cases (`see https://ex.com.` → token, period stays out).
- `restore_links` round-trips byte-exact (incl. underscores/queries in the URL).
- No-link input: `mask_links` returns input unchanged, empty mapping.
- Sentinel collision: input already containing `__OWLET_LINK_` bumps the prefix.
- Dropped token: output missing a token ⇒ `append_dropped` re-adds it.
- Dedupe: a link present in the output is **not** re-appended.

**Smoke (README, real model):** rewrite a draft containing a URL; confirm the URL
appears verbatim **and in place** in the result. If links frequently land in the
re-appended block at the bottom instead, suspect token mangling (e.g. the
markdown-emphasis pitfall above) — the unit tests control the token and won't
surface it.

---

# feat-008 — Per-rewrite context ("refine after")

## Decision: reuse the existing "Add context" chip

The result popup already ships an unwired "rewrite modes" chip row
(`ImprovePromptFloater.swift:178–190`, `enum ImproveMode` at `:272`) with a
`.context` case labeled **"Add context"** and a `TODO(v0.5)` to wire a `--mode`
flag. Rather than add a second, competing context mechanism, **feat-008 makes the
existing "Add context" chip functional**: tapping it reveals the free-text field
and Refine control. The other four chips (clarify/structured/examples/compact)
are **out of scope** for v0.4 — for this milestone the chip row renders only the
"Add context" chip; the `ImproveMode` enum is left intact for a future modes
feature that wires `--mode`.

## Interaction flow

1. Rewrite fires instantly and context-free on trigger — **today's fast path,
   untouched.** The `.result` popup appears with the diff.
2. The popup shows an **"Add context" chip**. Tapping it reveals an optional
   single-/two-line text field.
3. The user types a note and presses **Refine** (or Return in the field).
4. The rewrite re-runs **on the stored original source text** (no AX re-capture)
   with the note injected; the popup returns to loading, then to a fresh result.
5. Empty note + Refine is a no-op equivalent to "Try again".

The note influences only this refine pass; it is not persisted across separate
invocations.

## The macOS focus problem (primary implementation risk)

The popup is a `.nonactivatingPanel` (`PopupWindowController.swift:30`) that is
only ever `orderFrontRegardless()` — **never made key.** Existing buttons work
because mouse-down reaches controls without key status. **A `TextField` will not
receive keystrokes until the panel becomes key.** Two confirmed hazards:

1. **Self-dismiss on activation.** Dismiss is wired to
   `didActivateApplicationNotification` with `object: nil`
   (`PopupWindowController.swift:106–112`). If the field is made editable by
   calling `NSApp.activate()`, *Owlet's own* activation fires this observer →
   `hide()` → the popup dismisses itself the instant the user tries to type.
2. **Click-outside monitor** (`:90`) is a *global* monitor — it only sees clicks
   in other apps, so clicking the field itself does not dismiss. Good, but it
   must stay that way.

### Required design decision (not left to implementation)

- Set `panel.becomesKeyOnlyIfNeeded = true` so only a view that needs keyboard
  input (the text field) makes the panel key; buttons still do not.
- The panel must take key focus **without activating Owlet** (nonactivating
  panels can be key while the app stays in the background — the Spotlight-style
  pattern). Verify this empirically.
- **Fallback** if a nonactivating panel cannot reliably become key in this
  LSUIElement app: scope the app-switch dismiss observer to ignore Owlet's own
  bundle identifier, so activating to type does not self-dismiss.
- This class of bug (window mask / key status) was dead-in-app despite green
  unit tests in feat-005/006. **A README smoke step is mandatory:** "open the
  popup, tap Add context, type, press Refine."

## Context plumbing (Swift → Rust)

- **`Rewriting` protocol** (`OllamaClient.swift:120`) gains a context parameter:
  `func rewrite(_ input: String, context: String?) async throws -> String`.
  All conformers and test fakes update. `OllamaClient.rewrite` builds args
  per-call: `let args = context.map { arguments + ["--context", $0] } ?? arguments`
  (the stored `arguments` already carries `--model`).
- **`RewriterFlow`** stores the captured `snap.text` as `lastSourceText`. A new
  `refine(context:)` re-runs the rewrite on `lastSourceText` (no re-capture),
  routing through the same masking pipeline as feat-007. The initial `start()`
  call passes `context: nil`.
- **"Try again" consistency:** the existing `onRetry` re-runs `start()`, which
  re-captures from AX (`RewriterFlow.swift:56–64`). After the popup has taken
  focus, the original selection may be gone → `selectionEmpty`. Make "Try again"
  also re-run from `lastSourceText` so both refine and retry are robust.
- **Rust injection shape:** parse a new `--context <text>` flag. Inject by
  **prepending a delimited block to the user message** (Qwen3 expects a single
  system message — `main.rs:143`). The system prompt gains a short rule: a
  context block may precede the draft; apply it to guide the rewrite; **never
  echo the context in the output.** Empty/absent context ⇒ identical to today.
- Context is passed as a process argument (no shell), so it is injection-safe at
  the OS level. Cap the field at a few hundred characters in the UI.

## Architecture (feat-008)

### Modified files

| File | Change |
|------|--------|
| `tools/rewriter/src/main.rs` | Parse `--context`; inject into the user message; system-prompt rule. |
| `Owlet/Owlet/OllamaClient.swift` | `Rewriting.rewrite(_:context:)`; per-call arg assembly. |
| `Owlet/Owlet/RewriterFlow.swift` | Store `lastSourceText`; add `refine(context:)`; route Retry through it. |
| `Owlet/Owlet/Views/ImprovePromptFloater.swift` | Wire "Add context" chip → reveal field + Refine; render only that chip for v0.4; add `onRefine(String)` callback; `@FocusState` for the field. |
| `Owlet/Owlet/PopupWindowController.swift` | `becomesKeyOnlyIfNeeded`; ensure key-without-activation; (fallback) scope app-switch observer. |
| `feature_list.json` | Add feat-007 and feat-008 entries. |

## Testing (feat-008)

- **Rust:** `--context` parses; absent ⇒ default behavior; user message carries
  the delimited context block when present; `--context` with no value errors.
- **Swift:** `refine(context:)` calls the rewriter with stored text + the note;
  "Try again" re-runs from stored text; empty note behaves like retry.
- **Manual/smoke (focus path — no unit test covers it):** type in the field and
  Refine; confirm Replace still writes back to the original app; confirm
  click-outside still dismisses and typing does not self-dismiss.

---

## Verification commands

```bash
# feat-007 (Rust)
(cd tools/rewriter && cargo test)
# feat-007 smoke (real model)
(cd tools/rewriter && cargo build --release && bash tests/smoke.sh)

# feat-008 (Swift)
(cd Owlet && xcodegen generate && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS')

# Full
./init.sh
```

Paste a result line into each `feature_list.json` `evidence` field. Walk the new
README smoke steps for the feat-008 focus path.

---

## Future research appendix (non-blocking backlog)

Captured from the broader-sweep research; **not** part of this spec's
implementation:

- **Wire the remaining mode chips** (`--mode` flag: clarify/structured/examples/
  compact as canned prompt presets). The scaffolding and `TODO(v0.5)` already
  exist; this is the natural follow-on to feat-008.
- **Streaming output** — render the rewrite as it generates for perceived speed.
- **Response caching** — identical (input, model, context) ⇒ cached result.
- **Model keep-alive / warm-up** — reduce first-call latency.
- **Tone/length controls** — sliders or quick presets layered on context.

These are recorded for prioritization, not committed.
