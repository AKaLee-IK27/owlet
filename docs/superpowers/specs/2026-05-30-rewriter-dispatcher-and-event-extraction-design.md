# Rewriter Dispatcher + Event Extraction Design

**Date:** 2026-05-30
**Status:** Draft (awaiting user review)
**Feature IDs:** feat-009 (command dispatcher), feat-010 (wire mode chips), feat-011 (extract-event, text path), feat-012 (extract-event, image path)

> Brainstorming output. Two sub-projects under one design. SP1 (dispatcher) is the
> "upgrade the rewriter for FE and BE" ask and ships independently. SP2 (Pain 3
> event extraction) builds on top of it as a new command that returns structured
> data instead of rewritten text.

## Decisions captured from the brainstorming session

- **Direction:** explore-first (add new capability now), validation gap on the
  shipped core (no sad-test, Pain 1 not built) acknowledged as accepted risk.
- **Feature chosen:** dispatcher refactor + Pain 3 (event/reminder extraction).
- **Both input modalities** for Pain 3 (selected text *and* screenshot).
- **EventKit direct write** to Calendar/Reminders (with `.ics` fallback).
- **Vision stays in Swift `VisionClient`** — shared `EventDraft` schema, not a
  shared binary.
- **Mode chips wired** (multi-mode), Improve Prompt spec updated accordingly.
- **Defaulted, flippable on review** (the ask tool failed mid-session):
  - **Invocation = command palette** (one hotkey → menu) rather than N hotkeys.
  - **Vision model = `qwen2.5-vl:7b`** for extract-event image path; build SP2
    **staged** (text path first, image path second). Both modalities still ship.

## Relationship to the existing rewriter-options spec

`2026-05-29-rewriter-options-design.md` (feat-007 URL/email preservation, feat-008
per-rewrite context) is **not superseded**. Those two features slot into the
dispatcher pipeline:

- feat-007 masking/restore runs on `output_type: text` commands only.
- feat-008 `--context` becomes one of the structured options the dispatcher
  threads to any command.

Recommended ship order overall: **feat-007 → feat-008 → feat-009 → feat-010 →
feat-011 → feat-012**, one at a time per `CLAUDE.md`.

---

# SP1 — Command dispatcher (feat-009, feat-010)

## Problem

`owlet-rewriter` is single-purpose: one hardcoded `SYSTEM_PROMPT` (`main.rs:27`)
and one `--model` flag. Every "do a different language task on a selection" idea
(translate, summarize, extract an event, the unwired mode chips) is the **same
pipeline with a different system prompt and different output handling**. Adding
each as a bespoke path would re-litigate stdin reading, Ollama calling, error
mapping, and output cleaning every time.

There are also **two BE paths today**: the Rust CLI handles text
(`stdin → /api/chat`), and Swift `VisionClient` handles images (direct Ollama
call). Pain 3 needs both. The clean seam is a **shared output contract**, not a
shared binary: both paths produce the same typed result, and the FE consumes it
uniformly.

## BE — Rust `owlet-rewriter` becomes a command registry

### CLI surface

```
owlet-rewriter [--command <name>] [--model <name>] [--context <text>] [--mode <name>]
```

- `--command` — `improve` (default, **backward-compatible**) and `extract-event`
  ship in this milestone. `translate`/`summarize` are reserved registry names,
  not built here. Absent ⇒ `improve` ⇒ today's exact behavior.
- `--model` — existing.
- `--context` — feat-008; applies to any text command.
- `--mode` — feat-010; only meaningful for `improve`
  (clarify/structured/examples/compact).
- Unknown command or unknown flag ⇒ error (typos surface early, matching the
  current `parse_model_arg` philosophy).

### Command definition

Each command is a record:

```rust
struct Command {
    name: &'static str,
    system_prompt: &'static str,
    output: OutputType,          // Text | Json(schema)
    accepts_mode: bool,
    accepts_context: bool,
}

enum OutputType {
    Text,                        // clean_output + diff-friendly (today's path)
    Json(&'static str),          // Ollama `format` JSON schema; validated
}
```

The registry is a `const`/`static` table. `improve` keeps the exact current
`SYSTEM_PROMPT` and `OutputType::Text`. `extract-event` is `OutputType::Json(...)`
(SP2).

### Pipeline

```text
read stdin
  → resolve command from --command (default improve)
  → build messages (system = command.system_prompt; user = input [+ context block])
  → if output == Text: mask_links (feat-007) before send
  → call_ollama (payload carries `format` when output == Json)
  → parse_response
  → if output == Text:  clean_output → restore_links → append_dropped
     if output == Json: validate against schema (retry once on failure) → emit JSON
  → emit
```

No-command / no-link / no-context input ⇒ byte-identical to today.

### `--mode` (feat-010)

`improve` gains four directed variants. Implementation: a mode suffix appended to
(or selecting a variant of) the `improve` system prompt — clarify / structured /
examples / compact. Absent ⇒ the universal `improve` prompt unchanged.

**Improve Prompt spec update:** "single universal template" →
"1 universal + 4 directed modes." Record the decision in
`Owlet - Improve Prompt spec` and `docs/design-system.md` §8.

## FE — Swift dispatcher

- **`Rewriting` protocol** (already gaining `context:` in feat-008) generalizes to
  carry a command + options:
  `func run(command: Command, input: String, context: String?, mode: ImproveMode?) async throws -> RewriteResult`
  where `RewriteResult` is `.text(String)` or `.event(EventDraft)`.
- **`RewriterFlow`** becomes a dispatcher: `text` results render the existing
  diff floater; `event` results render the new `EventConfirmationCard` (SP2).
- **Mode chips** (`ImprovePromptFloater.swift:178`) wired: tapping a chip re-runs
  `improve` with `--mode`. The unwired-chip `TODO(v0.5)` is closed.
- **Command palette** (defaulted invocation): one configurable hotkey opens a
  small menu. For this milestone the menu lists only the commands that actually
  ship — **Improve** and **Extract event** (`translate`/`summarize` are reserved
  registry names, not yet built, so they do not appear). Selecting a command acts
  on the current selection (text commands) or starts a screenshot (image-capable
  commands). The existing `Option+Space` fast path for `improve` is **untouched**
  — the palette is additive.

## Architecture (SP1)

| File | Change |
|------|--------|
| `tools/rewriter/src/main.rs` | Command registry; `--command`/`--mode` parsing; `OutputType`; thread context; JSON path scaffold |
| `tools/rewriter/Cargo.toml` | (feat-007 already adds `linkify`); no new dep for SP1 |
| `Owlet/Owlet/OllamaClient.swift` | `Rewriting.run(command:input:context:mode:)`; `RewriteResult` |
| `Owlet/Owlet/RewriterFlow.swift` | Dispatch by result type; route Retry/Refine through stored source |
| `Owlet/Owlet/Views/ImprovePromptFloater.swift` | Wire mode chips → `--mode` |
| `Owlet/Owlet/CommandPaletteController.swift` (new) | Hotkey → command menu |
| `feature_list.json` | feat-009, feat-010 entries |

## Testing (SP1)

- **Rust:** `--command improve` (and absent) ⇒ identical payload to today;
  unknown command errors; `--mode` selects the right prompt variant; registry
  lookup; `Json` command sets `format` in the payload.
- **Swift:** dispatcher routes `.text` → floater and `.event` → card; mode chip
  tap re-runs with the mode; palette selection invokes the right command.
- **Smoke:** `Option+Space` still improves in place (regression); palette opens
  and each command runs.

---

# SP2 — Pain 3: event / reminder extraction (feat-011 text, feat-012 image)

## `EventDraft` — the shared contract

Defined once; produced by the Rust JSON path (text) and `VisionClient` (image);
consumed by `EventConfirmationCard` and the EventKit writer.

```
kind:     "event" | "reminder"
title:    string
start:    ISO8601 datetime | null
end:      ISO8601 datetime | null
allDay:   bool
location: string | null
notes:    string | null
```

Encoded as a JSON Schema for Ollama `format`, and as a `Codable` Swift struct.

## Reliability mechanics (the hard part: structured output from a local LLM)

1. **Inject "now" + timezone** into the prompt. Relative dates ("next Friday",
   "tomorrow 3pm") are meaningless without a reference instant. The caller passes
   the current local datetime + tz offset; the system prompt instructs the model
   to resolve relative dates against it and emit absolute ISO 8601.
2. **Ollama `format` = JSON schema** (structured outputs). The text path
   (`qwen3:8b`) supports this well — it constrains generation to the schema
   rather than free text.
3. **Validate + one retry.** Parse the JSON, validate against the schema. On
   failure, retry once; on a second failure, surface a clear error — never guess.
4. **Editable confirmation card is mandatory.** A 7B/8B model's date guess is
   never written to a calendar unseen. The user confirms/edits every field first.

## `EventConfirmationCard` — new FE surface

Branded, consistent with `ImprovePromptFloater`. Fields pre-filled from
`EventDraft`, all editable:

- Event / Reminder toggle
- Title (text)
- Start, End (date + time pickers)
- All-day toggle
- Location (text)
- Notes (text)
- **Calendar picker** (which `EKCalendar`)
- Primary action: **Add to Calendar** / **Add Reminder**

Reuses the design system primitives (`PrimaryButton`, `GhostButton`, paper/sage
palette). Lives alongside the existing popup states; the dispatcher shows it
instead of the diff view when the result is `.event`.

## EventKit integration

- `EKEventStore.requestFullAccessToEvents` / `requestFullAccessToReminders`
  (macOS 14+).
- Build `EKEvent` (title, startDate, endDate, location, notes, isAllDay,
  chosen calendar) or `EKReminder`; `save(...)`.
- **Info.plist:** `NSCalendarsFullAccessUsageDescription`,
  `NSRemindersFullAccessUsageDescription`.
- **Permission denied ⇒ `.ics` fallback:** write a `.ics` file and open it with
  the default calendar app, so the feature degrades instead of dying.
- Wrap `EKEventStore` behind a small protocol so the write path is unit-testable
  with a fake.

## Input paths

### Text path (feat-011, ships first)

Selection → `extract-event` command via the command palette → Rust CLI with
`--command extract-event` → JSON `EventDraft` → card → EventKit.

### Image path (feat-012, staged second)

Screenshot region → `VisionClient` taught to request the `EventDraft` schema from
the vision model → same card → same EventKit writer. Vision model for extract:
**`qwen2.5-vl:7b`** (stronger structured output than `llava:7b`, which stays for
screenshot-rewrite). Pulled lazily; documented as a prereq.

## Risks

| # | Risk | Severity | Mitigation |
|---|------|----------|------------|
| R1 | Vision structured output weak (`llava:7b`) | High | `qwen2.5-vl:7b` for extract; image path staged after text path proves the schema |
| R2 | Date/time/timezone/relative-date errors | Medium | Inject now+tz; editable card is the last line of defense |
| R3 | EventKit permission/entitlement; re-sign drops TCC grants | Medium | `.ics` fallback; document re-grant after each build |
| R4 | Milestone-sized scope while core is un-sad-tested | Medium | Accepted (explore-first); SP1 ships value early and independently |
| R5 | Trigger crowding | Low | Command palette instead of more chords |

## Architecture (SP2)

| File | Change |
|------|--------|
| `tools/rewriter/src/main.rs` | `extract-event` command: JSON schema, now+tz injection, validate+retry |
| `Owlet/Owlet/EventDraft.swift` (new) | `Codable` struct + schema |
| `Owlet/Owlet/EventKitWriter.swift` (new) | Protocol + `EKEventStore` impl + `.ics` fallback |
| `Owlet/Owlet/VisionClient.swift` | `extract-event` structured path (feat-012) |
| `Owlet/Owlet/Views/EventConfirmationCard.swift` (new) | Editable card |
| `Owlet/Owlet/RewriterFlow.swift` | `.event` result → card → writer |
| `Owlet/Owlet/PopupState.swift` | `.eventDraft(EventDraft)` state |
| `Owlet/Owlet.entitlements`, `Info.plist` | Calendar/Reminders usage descriptions |
| `feature_list.json` | feat-011, feat-012 entries |

## Testing (SP2)

- **Rust:** `extract-event` sets `format`; prompt carries current datetime;
  schema-valid output passes, malformed triggers one retry then errors;
  no `--command` still defaults to `improve`.
- **Swift:** `EventDraft` decodes (incl. null optionals, all-day, reminder kind);
  `EventKitWriter` creates the right `EKEvent`/`EKReminder` (fake store);
  permission-denied routes to `.ics`; `RewriterFlow` shows the card on `.event`.
- **Manual/smoke:** real email selection → card → Calendar entry correct;
  screenshot of a poster → card; a relative date ("next Friday") resolves to the
  right absolute date; permission prompt + denial fallback both walked.

---

## Verification commands

```bash
# Rust
(cd tools/rewriter && cargo test)
(cd tools/rewriter && cargo build --release && bash tests/smoke.sh)

# Swift
(cd Owlet && xcodegen generate && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS')

# Full
./init.sh
```

## Out of scope (recorded, not committed)

- Streaming output, response caching, model keep-alive, tone/length sliders
  (from the feat-007/008 backlog appendix).
- Pain 1 (VN↔EN) — `translate` is reserved as a command name in the registry, but
  building/tuning its template is a separate feature.
- Contact extraction, multi-event extraction from one source.
