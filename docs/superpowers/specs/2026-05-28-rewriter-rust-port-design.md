# Owlet — Rewriter Rust Port + L2 Prompt Redesign (v0.4)

**Date:** 2026-05-28
**Status:** Draft, pending user approval
**Scope:** Replace `tools/rewriter/rewrite_prompt.py` (Python CLI calling Ollama with an L1 grammar-polish system prompt) with a Rust binary that uses an L2 structural prompt engineering system prompt aligned to `Owlet - Improve Prompt spec.md`. The Swift app, popup UX, diff engine, hotkey, and permission flow are unchanged — only the spawned process binary and the system prompt change.

This spec is the implementation companion to `Owlet - Improve Prompt spec.md` (the product-level v1 spec maintained in the user's Obsidian vault).

## 1. Decisions locked in

| # | Decision | Rationale |
|---|---|---|
| 1 | **Rewrite the system prompt to L2 structural prompt engineering.** Replace the current "fix grammar, clarify English" prompt with one that applies specificity / output format / role / constraints / examples while preserving intent, tone, and scope. | The current Python prompt does L1 (grammar polish). The product spec explicitly says L1 is not the goal — frontier models already handle bad grammar. This is the substantive change in this PR. |
| 2 | **Port the CLI from Python to Rust.** Single static binary; drop the venv + `requests` install. | Eliminates Python venv brittleness in `install.sh`, ~10ms cold start vs ~80–120ms, one fewer toolchain (no `python3 -m venv`, no `pip`). Inference dominates wall-clock so this is NOT a model-throughput win — it's an install-simplicity and cold-start win. |
| 3 | **Preserve the language of the input.** Vietnamese input → improved Vietnamese. English input → improved English. Mixed VN/EN prose → keep the mix. **This supersedes the original product-spec decision (2026-05-28 "Output always EN")**. | User preference — they want to keep writing prompts in whichever language they're most comfortable with, including Vietnamese. The original rationale was "frontier model is stronger in EN"; user is willing to accept that tradeoff to avoid forced translation. |
| 4 | **Single universal template, no domain split, no few-shot.** | Matches the product spec's v1 scope. Few-shot examples are deferred — if Phase 1 validation (>70% useful) fails, revisit. |
| 5 | **`OllamaClient` and the spawn contract are unchanged.** stdin in, stdout out, stderr on error, same exit codes, same error-text heuristics (`Connection` substring → `ollamaDown` in `RewriterFlow.swift:75`). | Minimum blast radius. The Rust binary is a drop-in replacement at the process boundary. |
| 6 | **Drop Python entirely. No fallback.** Remove `rewrite_prompt.py`, `requirements.txt`, the venv. | Two implementations of the same contract is a maintenance burden for zero practical benefit — the Rust binary is self-contained and trivially rebuildable. |
| 7 | **Defer the "1-word / URL input → decline" edge case to Phase 2** as the product spec already permits. | Spec line 87: "Edge case này có thể defer Phase 2." Keeps v1 scope tight. |
| 8 | **Keep model = `qwen3:8b` for v1.** Model choice is an open question in the product spec; not gated by this work. | Spec line 103: model swap is Phase 1 validation work, not v1 implementation. |

## 2. Architecture

```
                ┌──────────────────────────────────────────────┐
                │              Owlet.app                       │
                │  (SwiftUI menu bar helper)                   │
                │                                              │
   fn+Ctrl+R ──►│  HotkeyEventTap ─► CaptureFlow ─► Popup     │
                │                          │                   │
                │                          ▼                   │
                │                     OllamaClient             │
                │                          │                   │
                │              spawns      ▼                   │
                │      ┌────────────────────────────────────┐  │
                │      │   tools/rewriter/owlet-rewriter    │  │
                │      │   (Rust binary)                    │  │
                │      │                                    │  │
                │      │   stdin ─► HTTP POST              │  │
                │      │       http://localhost:11434/api/chat
                │      │       model: qwen3:8b              │  │
                │      │       system: <L2 prompt>          │  │
                │      │   response ─► strip <think> ─►    │  │
                │      │   strip quotes ─► stdout           │  │
                │      └────────────────────────────────────┘  │
                └──────────────────────────────────────────────┘
```

What changes: the box labeled "rewrite_prompt.py (Python)" becomes "owlet-rewriter (Rust)". Everything else is identical.

## 3. The new system prompt

This is the most important change. Phrasing is the v1 starting point; tuning is empirical work during Phase 1 validation.

```text
You are a prompt engineering assistant. Rewrite the user's draft prompt — intended for a chat AI like Claude, GPT, or Gemini — so it produces better answers.

Apply structural prompt engineering. Do not just fix grammar or polish style — frontier models handle imperfect language fine. The improvement must be substantive.

# Language
Preserve the language of the input.
- Vietnamese input → improved Vietnamese.
- English input → improved English.
- Mixed Vietnamese prose with English technical terms → keep the mix; do not translate either way.
- Other languages → preserve.

All the structural improvements below apply in whichever language the user wrote in.

# What to improve (apply only where it serves the user's intent)
1. Specificity — replace vague words with concrete ones when the user's intent makes the right choice clear.
2. Output format — if the user implied a format (list, table, code block, JSON, steps), make it explicit.
3. Role / persona — if the task benefits from expertise, name the role the AI should adopt.
4. Constraints — if the user implied scope (length, audience, style, depth), state it explicitly.
5. Examples — if the task is ambiguous and 1–2 example patterns would clarify it, add one. Otherwise don't.

For code or technical prompts: specify language, runtime, or version when the user has implied them. Do not invent a stack the user didn't gesture at.

# What to preserve exactly
- Intent. Never add requirements the user didn't ask for.
- Tone and voice. Casual stays casual, playful stays playful, formal stays formal.
- Scope. Do not expand a small ask into a big one.

# What NOT to do
- No politeness filler ("Please", "I would like to", "Could you kindly").
- No invented constraints (no "max 200 words" if length wasn't implied).
- Do not over-specify a deliberately short prompt. "write a poem" stays open-ended — add gentle structure only if it clearly helps.
- No preamble, no explanation, no headers, no meta-commentary, no surrounding quotes or code fences.

# When the input is already a good prompt
Return it with minimal or no changes. Do not improve for the sake of improving.

# When the input is very long
Preserve the full content. Tighten only language and structure. Never summarize or truncate.

# Output
Only the rewritten prompt. Nothing else.
```

### Mapping to the product spec's improvement axes

| Product-spec axis (line) | Where covered in this prompt |
|---|---|
| Specificity (line 50) | "What to improve" §1 |
| Output format (line 51) | "What to improve" §2 |
| Role / persona (line 52) | "What to improve" §3 |
| Constraints (line 53) | "What to improve" §4 |
| Examples (line 54) | "What to improve" §5 |
| Preserve intent (line 58) | "What to preserve exactly" §Intent |
| Preserve tone/voice (line 59) | "What to preserve exactly" §Tone |
| Preserve scope (line 60) | "What to preserve exactly" §Scope |
| Don't add filler (line 72) | "What NOT to do" §1 |
| Don't hallucinate constraints (line 74) | "What NOT to do" §2 |
| Don't over-specify (lines 73, edge case line 84) | "What NOT to do" §3 |
| Preserve very-long prompts (line 85) | "When the input is very long" |
| Already-good prompt → minimal change (line 83) | "When the input is already a good prompt" |
| Code prompts → specify lang/version (line 86) | "What to improve" code/technical sub-rule |
| Language preservation | "Language" section (revises product-spec line 30) |

## 4. Component design

### 4.1 `tools/rewriter/Cargo.toml`

```toml
[package]
name = "owlet-rewriter"
version = "0.1.0"
edition = "2021"

[dependencies]
ureq = { version = "2", features = ["json"] }
serde_json = "1"

[profile.release]
opt-level = "z"
lto = true
strip = true
codegen-units = 1
```

Rationale for dep picks:
- **`ureq`** — blocking HTTP, no async runtime, ~few hundred KB compiled. We don't need streaming since `OllamaClient` already reads stdout in one shot (`readDataToEndOfFile`). Using `reqwest` would pull in `tokio` for no benefit.
- **`serde_json`** — request body construction + response parsing. The Ollama response is small enough to materialize in full.
- **No `regex`** — `<think>...</think>` stripping and quote stripping done with plain `str` operations. Keeps compile fast and binary <2 MB.

### 4.2 `tools/rewriter/src/main.rs` — module layout

```
main()                 read stdin, dispatch, write stdout, exit codes
  └─ rewrite(prompt)   build JSON, POST, parse, clean
       ├─ build_payload(prompt) -> serde_json::Value
       ├─ call_ollama(payload) -> Result<String, RewriteError>
       └─ clean_output(raw) -> String
            ├─ strip_think_blocks(s) -> String
            └─ strip_wrapping_quotes(s) -> String

enum RewriteError { Timeout, ConnectionRefused, Http(String), Json(String), Empty }

#[cfg(test)] mod tests { … }   inline unit tests
```

Why a single file: this is ~150–200 LOC. Splitting into modules would obscure rather than clarify.

### 4.3 Error contract (must match what `RewriterFlow.swift` already expects)

| Failure mode | stderr text | exit code |
|---|---|---|
| Empty stdin | (nothing) | 0 |
| Ollama timeout (>30s) | `ERROR: Ollama request timed out` | 1 |
| Ollama connection refused | `ERROR: Ollama unreachable; is 'ollama serve' running?` | 1 (the **`Connection`** substring is what `RewriterFlow.swift:75` keys on for `.ollamaDown`) |
| Non-200 HTTP | `ERROR: Ollama HTTP <code>: <body excerpt>` | 1 |
| JSON parse failure | `ERROR: malformed Ollama response: <reason>` | 1 |
| Empty model output | `ERROR: empty rewrite output` | 1 |

The Swift side already has heuristics on these strings; preserving exact phrasing where possible avoids touching Swift error mapping.

### 4.4 `<think>` block stripping

`qwen3:8b` emits chain-of-thought inside `<think>...</think>` even when `"think": false` is set (it's advisory). The Python script strips them with a regex; the Rust version does the same with a plain scanner:

```rust
fn strip_think_blocks(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut rest = input;
    while let Some(start) = rest.find("<think>") {
        out.push_str(&rest[..start]);
        match rest[start..].find("</think>") {
            Some(end) => rest = &rest[start + end + "</think>".len()..],
            None => return out + &rest[start..], // unterminated: emit as-is
        }
    }
    out + rest
}
```

Case-insensitive matching is not required; in practice the model emits lowercase tags.

## 5. Install flow changes (`install.sh`)

Remove:
- The Python venv block (current lines 32–45) and the `chmod +x rewrite_prompt.py` line.

Add (replacing the venv block):

```bash
# ---------- Rust toolchain check ----------
if ! command -v cargo >/dev/null 2>&1; then
  echo "ERROR: 'cargo' not found in PATH." >&2
  echo "       Install Rust via:" >&2
  echo "         curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh" >&2
  echo "       Then re-run install.sh." >&2
  exit 1
fi

# ---------- Build the rewriter binary ----------
echo "==> Building owlet-rewriter (Rust, release)"
(cd "$HERE/tools/rewriter" && cargo build --release --quiet)
cp "$HERE/tools/rewriter/target/release/owlet-rewriter" "$HERE/tools/rewriter/owlet-rewriter"
chmod +x "$HERE/tools/rewriter/owlet-rewriter"
```

Keep unchanged: the `defaults write co.greenpassport.owlet rewriterDirectory "$HERE/tools/rewriter"` line. Swift looks for the binary at `\(dir)/owlet-rewriter`.

## 6. Swift change (`Owlet/Owlet/RewriterFlow.swift`)

Two-line change at `makeDefaultRewriter()`:

```swift
// Before
return OllamaClient(
    executablePath: "\(dir)/.venv/bin/python3",
    arguments: ["\(dir)/rewrite_prompt.py"],
    timeoutSeconds: 30
)
// After
return OllamaClient(
    executablePath: "\(dir)/owlet-rewriter",
    arguments: [],
    timeoutSeconds: 30
)
```

No other Swift change. `OllamaClient`, `Rewriting`, `CleanOutput`, all tests untouched.

## 7. Tests

### Rust (inline `#[cfg(test)]` in `main.rs`)

- `strip_think_blocks` — empty, no-think, one block, multiple blocks, unterminated, non-greedy across two blocks.
- `strip_wrapping_quotes` — no quotes, `"..."`, `'...'`, mismatched, multiple quote chars inside (must NOT strip), already-trimmed.
- `parse_chat_response` — well-formed Ollama JSON, missing `message`, missing `content`, content with `<think>` block.

No integration tests against a real Ollama in CI — same as the current Python script's policy.

### Shell smoke test (`tools/rewriter/tests/smoke.sh`)

Mirror the existing `test_stdin_smoke.sh`:
1. stdin → non-empty, non-identical stdout.
2. Empty stdin → empty stdout, exit 0.
3. Clipboard untouched (write sentinel, run binary, verify `pbpaste` matches sentinel).

Run manually post-install. Not wired into CI.

### Swift (unchanged)

`OllamaClientTests.swift`, `RewriterFlowTests.swift`, `fake-rewriter.sh` — all keep working because they target the spawn contract (stdin/stdout/stderr/exit), which is preserved.

## 8. README changes

- "Customisation" section: change-the-prompt now points at `tools/rewriter/src/main.rs`; the model is still set in `src/main.rs`.
- Prerequisites: add `Rust toolchain (rustup)` alongside Ollama / Homebrew / Xcode.
- "Project layout" diagram: `tools/rewriter/` is now described as "Rust CLI (Ollama backend)" not "Python CLI".

## 9. Out of scope (deferred, with reason)

| Item | Where it lives | Why deferred |
|---|---|---|
| Few-shot examples in the system prompt | Phase 1 validation work | Product spec says single universal template, no few-shot, for v1. If validation <70% useful, revisit. |
| Single-word / URL input detection | Phase 2 | Product spec line 87 explicitly defers this. |
| Model swap (Qwen 2.5 / Llama 3.1 / Phi-3.5) | Phase 1 validation | Product spec line 103 lists it as an open question, not v1-gating. |
| Before/after preview at the model level | Already exists at popup level (`DiffEngine`) | Solved upstream. |
| Configurable hotkey, configurable prompt | v0.5+ | Not in any current spec; YAGNI. |

## 10. Risks and mitigations

| Risk | Mitigation |
|---|---|
| New prompt produces worse rewrites than the current one for the user's typical inputs. | Product spec already defines a 1-week validation window with a 70% useful threshold. If we miss it, tune phrasing first, then consider few-shot, then consider model swap — in that order. |
| `qwen3:8b` doesn't reliably preserve input language (a small 8B model may default to English on Vietnamese input). | Empirical — first thing to test in Phase 1 validation. If it fails, the prompt's language-preservation rule needs to be stronger (e.g., few-shot with a VN example) or the model needs to change. Captured as a Phase 1 question, not v1-blocking. |
| Rust toolchain absent on user's machine on first install. | install.sh prints the one-line rustup install command and exits cleanly. Same pattern as the existing `xcodegen` / `ollama` checks. |
| `<think>` blocks parsing differs subtly between Python regex and Rust scanner. | Inline unit tests cover the cases the regex handles (`.*?` DOTALL). Manual smoke test on `qwen3:8b` real output as part of post-implementation verification. |
| Stale `target/release/` build cached between runs of install.sh. | `cargo build --release` is idempotent and incremental; first-build cost is ~1–2 min, rebuild is seconds. Acceptable. |

## 11. Validation checklist (post-implementation)

- [ ] `tools/rewriter/owlet-rewriter` exists and is executable after `./install.sh`.
- [ ] `printf 'i want python code for csv read' | tools/rewriter/owlet-rewriter` returns a non-empty, modified prompt within ~5s.
- [ ] `printf '' | tools/rewriter/owlet-rewriter` exits 0 with empty stdout.
- [ ] With Ollama stopped (`ollama stop` / kill the daemon): stderr contains `Connection`, exit 1. Confirm Swift maps to `.ollamaDown`.
- [ ] In Owlet.app: select Vietnamese prose, fn+Ctrl+R → popup shows improved Vietnamese (not English).
- [ ] In Owlet.app: select an already-good English prompt, fn+Ctrl+R → popup shows the no-changes / minimal-change state.
- [ ] In Owlet.app: select a short prompt like "write a poem" → output stays open-ended, no invented constraints.
- [ ] All Swift unit tests still pass: `xcodebuild test -scheme Owlet`.

## 12. Decisions log

- 2026-05-28 — **Rust port + L2 prompt redesign as a single PR.** Both changes touch `tools/rewriter/` and ship together to avoid an awkward two-step migration.
- 2026-05-28 — **`ureq` over `reqwest`.** No async runtime needed; smaller binary.
- 2026-05-28 — **Preserve input language (revises product-spec "always EN").** User preference, accepts the tradeoff of weaker English-only frontier behavior in exchange for native-language workflow.
- 2026-05-28 — **No few-shot examples in v1.** Matches product-spec scope. Revisit only if Phase 1 validation falls below the 70% useful threshold.
- 2026-05-28 — **Drop Python entirely, no fallback.** Two implementations of the same contract is maintenance burden for no benefit.
