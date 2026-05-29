# URL & Email Preservation (feat-007) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Guarantee that URLs and email addresses in a draft survive the rewrite byte-for-byte, never mangled or silently dropped by the model.

**Architecture:** Placeholder masking, entirely inside the Rust rewriter. Before sending the draft to Ollama, replace each URL/email span with an opaque, markdown-safe ASCII token; after the model responds, restore the originals by exact-token replacement. Any link the model dropped is re-appended (label-free, deduped) so it is never lost.

**Tech Stack:** Rust, the [`linkify`](https://crates.io/crates/linkify) crate for robust link detection, existing `serde_json`/`ureq`.

**Ships first** (before feat-008): Rust-only, no UI, fully unit-testable without a model.

---

## File structure

| File | Responsibility |
|------|----------------|
| `tools/rewriter/Cargo.toml` | Add `linkify` dependency. |
| `tools/rewriter/src/main.rs` | Add `pick_prefix`, `mask_links`, `restore_links`, `append_dropped`; thread them through `run()`. All unit tests live in the existing `#[cfg(test)] mod tests`. |

`run()` becomes: `read stdin → (masked, originals, prefix) = mask_links(input) → raw = call_ollama(masked, model) → cleaned = clean_output(raw) → restored = restore_links(cleaned, originals, prefix) → final = append_dropped(restored, originals) → emit`.

**Design notes locked in from the spec:**
- Token form `OWLETLINKZ<n>Z` (prefix `OWLETLINKZ`, then index, then `Z`). ASCII (survives tokenization) and contains **no markdown-significant characters** — avoiding the `__OWLET_LINK_0__` trap where `__…__` is markdown strong-emphasis the model may normalize away.
- Restore uses **exact-token replacement** (no `regex` crate — keeps the dependency footprint minimal, matching the hand-rolled-arg-parsing ethos). Tokens are markdown-safe alnum, so they survive intact; a token the model altered is treated as dropped and handled by `append_dropped`.
- `linkify`'s default `LinkFinder` matches both URLs (scheme required, e.g. `https://…`) and emails. Scheme-required is intentional: it avoids false positives on bare words like `example.com`.

---

### Task 1: Add the linkify dependency

**Files:**
- Modify: `tools/rewriter/Cargo.toml`

- [ ] **Step 1: Add the dependency**

In `tools/rewriter/Cargo.toml`, under `[dependencies]`, add the `linkify` line:

```toml
[dependencies]
ureq = { version = "2", features = ["json"] }
serde_json = "1"
linkify = "0.10"
```

- [ ] **Step 2: Verify it resolves and the crate still builds**

Run: `(cd tools/rewriter && cargo build)`
Expected: PASS — `linkify` is fetched and compiled, build succeeds.

- [ ] **Step 3: Commit**

```bash
git add tools/rewriter/Cargo.toml tools/rewriter/Cargo.lock
git commit -m "feat(rewriter): add linkify dependency for URL detection (feat-007)"
```

---

### Task 2: `pick_prefix` — collision-safe token prefix

**Files:**
- Modify: `tools/rewriter/src/main.rs` (add function near `clean_output`; add tests to `mod tests`)

- [ ] **Step 1: Write the failing tests**

Add to `mod tests`:

```rust
#[test]
fn pick_prefix_default_when_no_collision() {
    assert_eq!(pick_prefix("plain text https://ex.com"), "OWLETLINKZ");
}

#[test]
fn pick_prefix_bumps_on_collision() {
    // Pathological input that literally contains the default prefix.
    let p = pick_prefix("weird OWLETLINKZ in the text");
    assert_ne!(p, "OWLETLINKZ");
    assert!(!"weird OWLETLINKZ in the text".contains(&p));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `(cd tools/rewriter && cargo test pick_prefix)`
Expected: FAIL — `cannot find function pick_prefix`.

- [ ] **Step 3: Implement `pick_prefix`**

Add to `main.rs` (above the tests module):

```rust
/// Choose a sentinel prefix that does not already occur in the input.
/// The default is `OWLETLINKZ`; only bumped for pathological inputs that
/// literally contain it (vanishingly rare). Tokens are `<prefix><index>Z`.
fn pick_prefix(input: &str) -> String {
    let base = "OWLETLINKZ";
    if !input.contains(base) {
        return base.to_string();
    }
    let mut n = 2;
    loop {
        let candidate = format!("OWLETLINK{n}Z");
        if !input.contains(&candidate) {
            return candidate;
        }
        n += 1;
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `(cd tools/rewriter && cargo test pick_prefix)`
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
git add tools/rewriter/src/main.rs
git commit -m "feat(rewriter): collision-safe sentinel prefix (feat-007)"
```

---

### Task 3: `mask_links` — replace links with tokens

**Files:**
- Modify: `tools/rewriter/src/main.rs`

- [ ] **Step 1: Write the failing tests**

Add to `mod tests`:

```rust
#[test]
fn mask_links_no_links_is_noop() {
    let (masked, originals, prefix) = mask_links("just some words");
    assert_eq!(masked, "just some words");
    assert!(originals.is_empty());
    assert_eq!(prefix, "");
}

#[test]
fn mask_links_replaces_url() {
    let (masked, originals, _prefix) = mask_links("see https://ex.com/a_b now");
    assert_eq!(masked, "see OWLETLINKZ0Z now");
    assert_eq!(originals, vec!["https://ex.com/a_b".to_string()]);
}

#[test]
fn mask_links_replaces_email_and_url_in_order() {
    let (masked, originals, _prefix) =
        mask_links("mail me@x.com or visit https://y.io");
    assert_eq!(masked, "mail OWLETLINKZ0Z or visit OWLETLINKZ1Z");
    assert_eq!(originals, vec!["me@x.com".to_string(), "https://y.io".to_string()]);
}

#[test]
fn mask_links_excludes_trailing_period() {
    // linkify keeps sentence punctuation out of the link span.
    let (masked, originals, _prefix) = mask_links("go to https://ex.com.");
    assert_eq!(masked, "go to OWLETLINKZ0Z.");
    assert_eq!(originals, vec!["https://ex.com".to_string()]);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `(cd tools/rewriter && cargo test mask_links)`
Expected: FAIL — `cannot find function mask_links`.

- [ ] **Step 3: Implement `mask_links`**

Add the import at the top of `main.rs` (with the other `use` lines):

```rust
use linkify::LinkFinder;
```

Add the function:

```rust
/// Replace every URL/email span with an opaque token `<prefix><index>Z`.
/// Returns (masked_text, originals_by_index, prefix). No links → input
/// unchanged, empty originals, empty prefix.
fn mask_links(input: &str) -> (String, Vec<String>, String) {
    let finder = LinkFinder::new(); // URLs (scheme required) + emails
    let links: Vec<_> = finder.links(input).collect();
    if links.is_empty() {
        return (input.to_string(), Vec::new(), String::new());
    }
    let prefix = pick_prefix(input);
    let mut originals: Vec<String> = Vec::with_capacity(links.len());
    let mut masked = String::with_capacity(input.len());
    let mut last = 0;
    for link in &links {
        masked.push_str(&input[last..link.start()]);
        masked.push_str(&format!("{}{}Z", prefix, originals.len()));
        originals.push(link.as_str().to_string());
        last = link.end();
    }
    masked.push_str(&input[last..]);
    (masked, originals, prefix)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `(cd tools/rewriter && cargo test mask_links)`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add tools/rewriter/src/main.rs
git commit -m "feat(rewriter): mask_links masks URLs/emails with tokens (feat-007)"
```

---

### Task 4: `restore_links` — swap tokens back

**Files:**
- Modify: `tools/rewriter/src/main.rs`

- [ ] **Step 1: Write the failing tests**

Add to `mod tests`:

```rust
#[test]
fn restore_links_round_trips_exact() {
    let originals = vec!["https://ex.com/a_b?x=1".to_string()];
    let restored = restore_links("see OWLETLINKZ0Z now", &originals, "OWLETLINKZ");
    assert_eq!(restored, "see https://ex.com/a_b?x=1 now");
}

#[test]
fn restore_links_multiple() {
    let originals = vec!["me@x.com".to_string(), "https://y.io".to_string()];
    let restored =
        restore_links("mail OWLETLINKZ0Z or OWLETLINKZ1Z", &originals, "OWLETLINKZ");
    assert_eq!(restored, "mail me@x.com or https://y.io");
}

#[test]
fn restore_links_missing_token_left_as_is() {
    // Model dropped token 0; restore touches only what is present.
    let originals = vec!["https://gone.com".to_string(), "https://kept.io".to_string()];
    let restored = restore_links("only OWLETLINKZ1Z survived", &originals, "OWLETLINKZ");
    assert_eq!(restored, "only https://kept.io survived");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `(cd tools/rewriter && cargo test restore_links)`
Expected: FAIL — `cannot find function restore_links`.

- [ ] **Step 3: Implement `restore_links`**

```rust
/// Replace each exact token `<prefix><index>Z` with its original span.
/// Tokens the model dropped or altered simply aren't found and are left
/// for `append_dropped` to recover.
fn restore_links(text: &str, originals: &[String], prefix: &str) -> String {
    let mut out = text.to_string();
    for (i, original) in originals.iter().enumerate() {
        let token = format!("{prefix}{i}Z");
        out = out.replace(&token, original);
    }
    out
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `(cd tools/rewriter && cargo test restore_links)`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
git add tools/rewriter/src/main.rs
git commit -m "feat(rewriter): restore_links swaps tokens back to originals (feat-007)"
```

---

### Task 5: `append_dropped` — recover lost links (deduped, label-free)

**Files:**
- Modify: `tools/rewriter/src/main.rs`

- [ ] **Step 1: Write the failing tests**

Add to `mod tests`:

```rust
#[test]
fn append_dropped_noop_when_all_present() {
    let originals = vec!["https://kept.io".to_string()];
    let out = append_dropped("text with https://kept.io inside", &originals);
    assert_eq!(out, "text with https://kept.io inside");
}

#[test]
fn append_dropped_appends_missing_label_free() {
    let originals = vec!["https://gone.com".to_string()];
    let out = append_dropped("rewritten text", &originals);
    assert_eq!(out, "rewritten text\n\nhttps://gone.com");
}

#[test]
fn append_dropped_dedupes_repeated_url() {
    // Same URL appeared twice in the input; one copy survived in the text.
    let originals = vec!["https://dup.io".to_string(), "https://dup.io".to_string()];
    let out = append_dropped("kept https://dup.io once", &originals);
    // Already present in the text → nothing appended.
    assert_eq!(out, "kept https://dup.io once");
}

#[test]
fn append_dropped_multiple_missing_each_on_own_line() {
    let originals = vec!["https://a.com".to_string(), "https://b.com".to_string()];
    let out = append_dropped("nothing here", &originals);
    assert_eq!(out, "nothing here\n\nhttps://a.com\nhttps://b.com");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `(cd tools/rewriter && cargo test append_dropped)`
Expected: FAIL — `cannot find function append_dropped`.

- [ ] **Step 3: Implement `append_dropped`**

```rust
/// Re-append any original link not already literally present in `text`,
/// label-free (a hardcoded header would break language preservation),
/// deduped (the model never sees the literal URL, so the only dedupe case
/// is the same URL repeated in the input). Each appended link on its own
/// line, after one blank line.
fn append_dropped(text: &str, originals: &[String]) -> String {
    let mut dropped: Vec<&str> = Vec::new();
    for original in originals {
        let present_in_text = text.contains(original.as_str());
        let already_queued = dropped.iter().any(|d| *d == original.as_str());
        if !present_in_text && !already_queued {
            dropped.push(original.as_str());
        }
    }
    if dropped.is_empty() {
        return text.to_string();
    }
    let mut out = text.trim_end().to_string();
    out.push_str("\n\n");
    out.push_str(&dropped.join("\n"));
    out
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `(cd tools/rewriter && cargo test append_dropped)`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add tools/rewriter/src/main.rs
git commit -m "feat(rewriter): append_dropped recovers lost links (feat-007)"
```

---

### Task 6: Thread masking through `run()`

**Files:**
- Modify: `tools/rewriter/src/main.rs:191-206` (the `run` function)

- [ ] **Step 1: Replace the body of `run` after the empty-input guard**

Current code:

```rust
    let raw = call_ollama(&input, &model)?;
    let cleaned = clean_output(&raw);
    if cleaned.trim().is_empty() {
        return Err(RewriteError::Empty);
    }
    Ok(Some(cleaned))
```

Replace with:

```rust
    let (masked, originals, prefix) = mask_links(&input);
    let raw = call_ollama(&masked, &model)?;
    let cleaned = clean_output(&raw);
    if cleaned.trim().is_empty() {
        return Err(RewriteError::Empty);
    }
    let restored = restore_links(&cleaned, &originals, &prefix);
    let final_text = append_dropped(&restored, &originals);
    Ok(Some(final_text))
```

- [ ] **Step 2: Run the full Rust suite**

Run: `(cd tools/rewriter && cargo test)`
Expected: PASS — all prior tests plus the 13 new masking tests.

- [ ] **Step 3: Commit**

```bash
git add tools/rewriter/src/main.rs
git commit -m "feat(rewriter): wire link masking into run() (feat-007)"
```

---

### Task 7: Real-model smoke + evidence

**Files:**
- Modify: `feature_list.json` (add the feat-007 entry)
- Modify: `README.md` (add the smoke step under the manual checklist)

- [ ] **Step 1: Run the Ollama smoke (requires `ollama serve` + `qwen3:8b`)**

Run:
```bash
(cd tools/rewriter && cargo build --release && \
  printf 'make this clearer: check the docs at https://example.com/getting_started?ref=abc' \
  | ./target/release/owlet-rewriter)
```
Expected: the rewritten prompt contains `https://example.com/getting_started?ref=abc` **verbatim and in place** (not relocated to a trailing block). If the URL lands at the bottom instead, suspect token mangling — confirm the token form is markdown-safe alnum.

- [ ] **Step 2: Add the README smoke step**

Under the manual smoke-test checklist in `README.md`, add:

```markdown
- **URL preservation:** rewrite a draft containing a URL (e.g. `https://example.com/a_b?x=1`). Confirm the URL appears in the result byte-for-byte, in place.
```

- [ ] **Step 3: Add the feature_list.json entry**

Add to the `features` array in `feature_list.json`:

```json
{
  "id": "feat-007",
  "name": "URL & email preservation in rewriter",
  "description": "Placeholder masking in the Rust rewriter: linkify finds URLs/emails, masks each with a markdown-safe token before Ollama, restores exact originals after. Dropped links re-appended (deduped, label-free). Spec: docs/superpowers/specs/2026-05-29-rewriter-options-design.md.",
  "dependencies": [],
  "status": "done",
  "evidence": ""
}
```

- [ ] **Step 4: Paste evidence**

Fill the `evidence` field with the result of `(cd tools/rewriter && cargo test)` (e.g. "Rust NN/NN pass") and the Step 1 smoke output line showing the URL preserved verbatim.

- [ ] **Step 5: Commit**

```bash
git add feature_list.json README.md
git commit -m "docs(feat-007): smoke step + feature_list evidence"
```

---

## Self-review checklist (run before handing off)

- [ ] **Spec coverage:** masking mechanism (T2–T4), dropped-link re-append deduped/label-free (T5), run() wiring (T6), emails in scope (T3), markdown-safe sentinel (T2/T3), smoke step (T7) — all present.
- [ ] **Placeholder scan:** no TBD/TODO; every code step shows full code.
- [ ] **Type consistency:** `mask_links → (String, Vec<String>, String)`; `restore_links(text, originals, prefix)`; `append_dropped(text, originals)`; token form `OWLETLINKZ<n>Z` consistent across T2–T6.
- [ ] **Final gate:** `./init.sh` passes from a clean checkout.
