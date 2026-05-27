# Owlet Rewriter Rust Port + L2 Prompt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `tools/rewriter/rewrite_prompt.py` with a Rust binary (`tools/rewriter/owlet-rewriter`) that uses the new L2 structural prompt engineering system prompt (preserves input language). The Swift app's spawn contract is unchanged — only the spawned binary, the system prompt, and the install flow change.

**Architecture:** Single-file Rust binary using `ureq` (sync HTTP, no async runtime) for the Ollama call. The binary reads from stdin, POSTs to `http://localhost:11434/api/chat`, strips `<think>` blocks and wrapping quotes from the response, and writes the result to stdout. Error contract (stderr phrasing + exit codes) preserved so existing Swift error mapping (`RewriterFlow.swift:67-86`) is untouched.

**Tech Stack:** Rust 2021 edition · `ureq` 2.x · `serde_json` 1.x · `cargo` build. Backend Ollama model unchanged at `qwen3:8b`. Swift integration is a 2-line path change in `RewriterFlow.swift`.

**Design spec:** `docs/superpowers/specs/2026-05-28-rewriter-rust-port-design.md` (read first if you're picking this up cold).

---

## Phase A — Rust crate scaffold and pure functions (TDD-friendly)

### Task 1: Scaffold the Cargo crate

**Files:**
- Create: `tools/rewriter/Cargo.toml`
- Create: `tools/rewriter/.gitignore`
- Create: `tools/rewriter/src/main.rs` (compiling stub)

- [ ] **Step 1: Create `tools/rewriter/Cargo.toml`**

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

- [ ] **Step 2: Create `tools/rewriter/.gitignore`**

```
target/
```

- [ ] **Step 3: Create `tools/rewriter/src/main.rs` as a compiling stub**

```rust
fn main() {
    eprintln!("owlet-rewriter: stub, not yet implemented");
    std::process::exit(1);
}
```

- [ ] **Step 4: Verify it builds**

Run: `cd tools/rewriter && cargo build`
Expected: `Compiling owlet-rewriter v0.1.0` followed by `Finished dev` (first build downloads `ureq` + `serde_json` + transitive deps, ~30–60s).

- [ ] **Step 5: Commit**

```bash
git add tools/rewriter/Cargo.toml tools/rewriter/Cargo.lock tools/rewriter/.gitignore tools/rewriter/src/main.rs
git commit -m "scaffold(rewriter): cargo crate, ureq + serde_json deps"
```

---

### Task 2: Implement string cleaners (TDD)

Three pure functions that strip `<think>...</think>` blocks and matching wrapping quotes. These exactly mirror the Python script's behavior so qwen3:8b's output is processed identically.

**Files:**
- Modify: `tools/rewriter/src/main.rs`

- [ ] **Step 1: Add a `#[cfg(test)]` module and failing tests for `strip_think_blocks`**

Replace the entire `main.rs` content with:

```rust
fn strip_think_blocks(_input: &str) -> String {
    unimplemented!()
}

fn main() {
    eprintln!("owlet-rewriter: stub, not yet implemented");
    std::process::exit(1);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strip_think_empty() {
        assert_eq!(strip_think_blocks(""), "");
    }

    #[test]
    fn strip_think_no_block() {
        assert_eq!(strip_think_blocks("hello world"), "hello world");
    }

    #[test]
    fn strip_think_single_block() {
        assert_eq!(strip_think_blocks("hi <think>blah</think> there"), "hi  there");
    }

    #[test]
    fn strip_think_multiple_blocks() {
        assert_eq!(strip_think_blocks("a<think>1</think>b<think>2</think>c"), "abc");
    }

    #[test]
    fn strip_think_unterminated_emits_as_is() {
        assert_eq!(strip_think_blocks("hi <think>unfinished"), "hi <think>unfinished");
    }

    #[test]
    fn strip_think_multiline_block() {
        assert_eq!(
            strip_think_blocks("a<think>\nlots\nof\nstuff\n</think>b"),
            "ab"
        );
    }
}
```

- [ ] **Step 2: Run tests; expect compile error on `unimplemented!()`**

Run: `cd tools/rewriter && cargo test`
Expected: tests panic with `not yet implemented` (the function compiles but panics at call time).

- [ ] **Step 3: Implement `strip_think_blocks`**

Replace the function body:

```rust
fn strip_think_blocks(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut rest = input;
    while let Some(start) = rest.find("<think>") {
        out.push_str(&rest[..start]);
        let after_open = &rest[start + "<think>".len()..];
        match after_open.find("</think>") {
            Some(end_rel) => rest = &after_open[end_rel + "</think>".len()..],
            None => {
                out.push_str(&rest[start..]); // unterminated — emit as-is
                return out;
            }
        }
    }
    out.push_str(rest);
    out
}
```

- [ ] **Step 4: Run tests; expect all six to pass**

Run: `cd tools/rewriter && cargo test strip_think`
Expected: `test result: ok. 6 passed`.

- [ ] **Step 5: Add `strip_wrapping_quotes` failing tests**

Append to the `tests` module:

```rust
    #[test]
    fn strip_quotes_none() {
        assert_eq!(strip_wrapping_quotes("hello"), "hello");
    }

    #[test]
    fn strip_quotes_double() {
        assert_eq!(strip_wrapping_quotes("\"hello\""), "hello");
    }

    #[test]
    fn strip_quotes_single() {
        assert_eq!(strip_wrapping_quotes("'hello'"), "hello");
    }

    #[test]
    fn strip_quotes_mismatched_not_stripped() {
        assert_eq!(strip_wrapping_quotes("\"hello'"), "\"hello'");
    }

    #[test]
    fn strip_quotes_three_quote_chars_not_stripped() {
        // Quote count != 2 — preserve as-is (matches Python script behavior).
        assert_eq!(strip_wrapping_quotes("\"he\"llo"), "\"he\"llo");
    }

    #[test]
    fn strip_quotes_trims_whitespace_inside() {
        assert_eq!(strip_wrapping_quotes("  \"hello\"  "), "hello");
    }
```

And add a stub:

```rust
fn strip_wrapping_quotes(_input: &str) -> String {
    unimplemented!()
}
```

- [ ] **Step 6: Run; expect failures, then implement**

Run: `cd tools/rewriter && cargo test strip_quotes`
Expected: 6 panics on `unimplemented!()`.

Implement:

```rust
fn strip_wrapping_quotes(input: &str) -> String {
    let trimmed = input.trim();
    let bytes = trimmed.as_bytes();
    if bytes.len() >= 2 {
        let first = bytes[0];
        let last = bytes[bytes.len() - 1];
        if (first == b'"' || first == b'\'') && first == last {
            let count = bytes.iter().filter(|&&b| b == first).count();
            if count == 2 {
                return trimmed[1..trimmed.len() - 1].trim().to_string();
            }
        }
    }
    trimmed.to_string()
}
```

- [ ] **Step 7: Re-run; expect all pass**

Run: `cd tools/rewriter && cargo test strip_quotes`
Expected: `test result: ok. 6 passed`.

- [ ] **Step 8: Add `clean_output` composer with a test**

```rust
fn clean_output(raw: &str) -> String {
    strip_wrapping_quotes(&strip_think_blocks(raw))
}
```

In the `tests` mod:

```rust
    #[test]
    fn clean_output_strips_think_then_quotes() {
        let raw = "<think>internal</think>\"the answer\"";
        assert_eq!(clean_output(raw), "the answer");
    }
```

- [ ] **Step 9: Run; expect all clean_output tests pass**

Run: `cd tools/rewriter && cargo test`
Expected: `test result: ok. 13 passed`.

- [ ] **Step 10: Commit**

```bash
git add tools/rewriter/src/main.rs
git commit -m "feat(rewriter): strip <think> blocks + wrapping quotes (TDD)"
```

---

### Task 3: Parse the Ollama chat response (TDD)

Parses `{"message":{"content":"..."}}` from `/api/chat`. Failure modes (malformed JSON, missing fields) return a structured error.

**Files:**
- Modify: `tools/rewriter/src/main.rs`

- [ ] **Step 1: Add the error enum near the top of `main.rs`**

```rust
#[derive(Debug)]
enum RewriteError {
    Timeout,
    ConnectionRefused,
    Http(String),
    Parse(String),
    Empty,
}
```

- [ ] **Step 2: Add failing tests for `parse_response`**

In the `tests` module:

```rust
    #[test]
    fn parse_response_ok() {
        let body = r#"{"message":{"content":"the rewrite"}}"#;
        assert_eq!(parse_response(body).unwrap(), "the rewrite");
    }

    #[test]
    fn parse_response_missing_message_returns_parse_err() {
        let body = r#"{}"#;
        assert!(matches!(parse_response(body), Err(RewriteError::Parse(_))));
    }

    #[test]
    fn parse_response_missing_content_returns_parse_err() {
        let body = r#"{"message":{}}"#;
        assert!(matches!(parse_response(body), Err(RewriteError::Parse(_))));
    }

    #[test]
    fn parse_response_invalid_json_returns_parse_err() {
        assert!(matches!(parse_response("not json"), Err(RewriteError::Parse(_))));
    }

    #[test]
    fn parse_response_preserves_think_block_for_later_strip() {
        // parse_response is just JSON extraction. <think> stripping happens later.
        let body = r#"{"message":{"content":"<think>x</think>final"}}"#;
        assert_eq!(parse_response(body).unwrap(), "<think>x</think>final");
    }
```

And a stub:

```rust
fn parse_response(_body: &str) -> Result<String, RewriteError> {
    unimplemented!()
}
```

- [ ] **Step 3: Run; expect panics**

Run: `cd tools/rewriter && cargo test parse_response`
Expected: 5 panics.

- [ ] **Step 4: Implement `parse_response`**

```rust
fn parse_response(body: &str) -> Result<String, RewriteError> {
    let v: serde_json::Value =
        serde_json::from_str(body).map_err(|e| RewriteError::Parse(e.to_string()))?;
    v.get("message")
        .and_then(|m| m.get("content"))
        .and_then(|c| c.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| RewriteError::Parse("missing message.content".into()))
}
```

- [ ] **Step 5: Run; expect all pass**

Run: `cd tools/rewriter && cargo test parse_response`
Expected: `test result: ok. 5 passed`.

- [ ] **Step 6: Commit**

```bash
git add tools/rewriter/src/main.rs
git commit -m "feat(rewriter): parse Ollama chat response JSON"
```

---

### Task 4: `RewriteError::stderr_message` (TDD)

Stable stderr strings that Swift error-mapping keys on. The `Connection` substring in the connection-refused case is what `RewriterFlow.swift:75`'s `.localizedCaseInsensitiveContains("Connection")` matches to produce `.ollamaDown`.

**Files:**
- Modify: `tools/rewriter/src/main.rs`

- [ ] **Step 1: Add failing tests in the `tests` module**

```rust
    #[test]
    fn stderr_timeout_phrasing() {
        assert_eq!(
            RewriteError::Timeout.stderr_message(),
            "ERROR: Ollama request timed out"
        );
    }

    #[test]
    fn stderr_connection_refused_phrasing() {
        let msg = RewriteError::ConnectionRefused.stderr_message();
        assert_eq!(
            msg,
            "ERROR: Connection to Ollama refused; is 'ollama serve' running?"
        );
        // Swift heuristic in RewriterFlow.swift:75 keys on "Connection" (case-insensitive).
        assert!(msg.to_lowercase().contains("connection"));
    }

    #[test]
    fn stderr_empty_phrasing() {
        assert_eq!(
            RewriteError::Empty.stderr_message(),
            "ERROR: empty rewrite output"
        );
    }

    #[test]
    fn stderr_http_includes_inner_message() {
        let m = RewriteError::Http("500 boom".into()).stderr_message();
        assert!(m.starts_with("ERROR:"));
        assert!(m.contains("500 boom"));
    }

    #[test]
    fn stderr_parse_includes_inner_reason() {
        let m = RewriteError::Parse("missing message.content".into()).stderr_message();
        assert!(m.starts_with("ERROR:"));
        assert!(m.contains("missing message.content"));
    }
```

- [ ] **Step 2: Add a stub and run**

```rust
impl RewriteError {
    fn stderr_message(&self) -> String {
        unimplemented!()
    }
}
```

Run: `cd tools/rewriter && cargo test stderr_`
Expected: 5 panics.

- [ ] **Step 3: Implement `stderr_message`**

```rust
impl RewriteError {
    fn stderr_message(&self) -> String {
        match self {
            RewriteError::Timeout => "ERROR: Ollama request timed out".into(),
            RewriteError::ConnectionRefused => {
                "ERROR: Connection to Ollama refused; is 'ollama serve' running?".into()
            }
            RewriteError::Http(detail) => format!("ERROR: Ollama HTTP error: {detail}"),
            RewriteError::Parse(reason) => format!("ERROR: malformed Ollama response: {reason}"),
            RewriteError::Empty => "ERROR: empty rewrite output".into(),
        }
    }
}
```

- [ ] **Step 4: Re-run; expect pass**

Run: `cd tools/rewriter && cargo test stderr_`
Expected: `test result: ok. 5 passed`.

- [ ] **Step 5: Commit**

```bash
git add tools/rewriter/src/main.rs
git commit -m "feat(rewriter): RewriteError + stderr phrasings matching Swift heuristics"
```

---

### Task 5: System prompt constant and `build_payload` (TDD)

The L2 system prompt is the substantive change of this PR. The structure of the request is verified by a shape test; the prompt text is verified live in Task 12.

**Files:**
- Modify: `tools/rewriter/src/main.rs`

- [ ] **Step 1: Add constants near the top of `main.rs`**

```rust
const OLLAMA_URL: &str = "http://localhost:11434/api/chat";
const MODEL: &str = "qwen3:8b";
const TIMEOUT_SECS: u64 = 30;

const SYSTEM_PROMPT: &str = r#"You are a prompt engineering assistant. Rewrite the user's draft prompt — intended for a chat AI like Claude, GPT, or Gemini — so it produces better answers.

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
5. Examples — if the task is ambiguous and 1-2 example patterns would clarify it, add one. Otherwise don't.

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
Only the rewritten prompt. Nothing else."#;
```

- [ ] **Step 2: Add a failing shape test for `build_payload`**

```rust
    #[test]
    fn build_payload_has_expected_shape() {
        let p = build_payload("rewrite me");
        assert_eq!(p["model"], MODEL);
        assert_eq!(p["stream"], false);
        assert_eq!(p["think"], false);
        assert_eq!(p["options"]["temperature"], 0.2);
        let msgs = p["messages"].as_array().expect("messages array");
        assert_eq!(msgs.len(), 2);
        assert_eq!(msgs[0]["role"], "system");
        assert_eq!(msgs[1]["role"], "user");
        assert_eq!(msgs[1]["content"], "rewrite me");
        let sys_text = msgs[0]["content"].as_str().unwrap();
        // Anchor on a phrase guaranteed by the spec — change the assertion if the prompt is intentionally restructured.
        assert!(sys_text.contains("prompt engineering assistant"));
        assert!(sys_text.contains("Preserve the language of the input"));
    }
```

And a stub:

```rust
fn build_payload(_prompt: &str) -> serde_json::Value {
    unimplemented!()
}
```

- [ ] **Step 3: Run; expect panic**

Run: `cd tools/rewriter && cargo test build_payload`
Expected: 1 panic.

- [ ] **Step 4: Implement `build_payload`**

```rust
fn build_payload(prompt: &str) -> serde_json::Value {
    serde_json::json!({
        "model": MODEL,
        "messages": [
            { "role": "system", "content": SYSTEM_PROMPT },
            { "role": "user",   "content": prompt },
        ],
        "stream": false,
        "think": false,
        "options": { "temperature": 0.2 }
    })
}
```

- [ ] **Step 5: Run; expect pass**

Run: `cd tools/rewriter && cargo test build_payload`
Expected: `test result: ok. 1 passed`.

- [ ] **Step 6: Commit**

```bash
git add tools/rewriter/src/main.rs
git commit -m "feat(rewriter): L2 system prompt + build_payload"
```

---

## Phase B — HTTP and main entrypoint

### Task 6: `call_ollama` HTTP wrapper

No unit test for this — the failure modes (timeout, connection refused, non-200) are network behaviors validated via the smoke test in Task 7 and the live checklist in Task 12.

**Files:**
- Modify: `tools/rewriter/src/main.rs`

- [ ] **Step 1: Add `call_ollama` to `main.rs` (below `parse_response`)**

```rust
use std::time::Duration;

fn call_ollama(prompt: &str) -> Result<String, RewriteError> {
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(TIMEOUT_SECS))
        .build();
    let payload = build_payload(prompt);
    match agent.post(OLLAMA_URL).send_json(payload) {
        Ok(response) => {
            let body = response
                .into_string()
                .map_err(|e| RewriteError::Parse(e.to_string()))?;
            parse_response(&body)
        }
        Err(ureq::Error::Status(code, response)) => {
            let body = response.into_string().unwrap_or_default();
            let excerpt: String = body.chars().take(200).collect();
            Err(RewriteError::Http(format!("HTTP {code}: {excerpt}")))
        }
        Err(ureq::Error::Transport(transport)) => {
            let kind = transport.kind();
            let msg = transport.message().unwrap_or("").to_lowercase();
            if msg.contains("timed out") || msg.contains("timeout") {
                Err(RewriteError::Timeout)
            } else if matches!(kind, ureq::ErrorKind::ConnectionFailed)
                || msg.contains("refused")
            {
                Err(RewriteError::ConnectionRefused)
            } else {
                Err(RewriteError::Http(format!("{kind:?}: {msg}")))
            }
        }
    }
}
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `cd tools/rewriter && cargo build`
Expected: `Finished dev` with no errors. If ureq's `ErrorKind` variant names have shifted in a newer minor, adjust the `matches!` arm — phrasing-based fallback (`msg.contains("refused")`) is the load-bearing detection path.

- [ ] **Step 3: Commit**

```bash
git add tools/rewriter/src/main.rs
git commit -m "feat(rewriter): call_ollama HTTP wrapper with error classification"
```

---

### Task 7: `run()` and `main()` entrypoint

Wire stdin → `call_ollama` → `clean_output` → stdout, with the documented exit codes and stderr phrasing.

**Files:**
- Modify: `tools/rewriter/src/main.rs`

- [ ] **Step 1: Replace the placeholder `main` with the real implementation**

Remove the existing stub `main` and add:

```rust
use std::io::{self, Read, Write};
use std::process::ExitCode;

fn run() -> Result<Option<String>, RewriteError> {
    let mut input = String::new();
    io::stdin()
        .read_to_string(&mut input)
        .map_err(|e| RewriteError::Parse(format!("stdin: {e}")))?;
    if input.trim().is_empty() {
        return Ok(None);
    }
    let raw = call_ollama(&input)?;
    let cleaned = clean_output(&raw);
    if cleaned.trim().is_empty() {
        return Err(RewriteError::Empty);
    }
    Ok(Some(cleaned))
}

fn main() -> ExitCode {
    match run() {
        Ok(Some(s)) => {
            // Use write! on stdout (not println!) so we don't append a newline
            // the Python script also didn't add.
            let stdout = io::stdout();
            let mut handle = stdout.lock();
            if let Err(e) = handle.write_all(s.as_bytes()) {
                eprintln!("ERROR: stdout write failed: {e}");
                return ExitCode::FAILURE;
            }
            ExitCode::SUCCESS
        }
        Ok(None) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("{}", err.stderr_message());
            ExitCode::FAILURE
        }
    }
}
```

- [ ] **Step 2: Build and confirm it compiles**

Run: `cd tools/rewriter && cargo build --release`
Expected: `Finished release` profile. Confirm binary exists: `ls tools/rewriter/target/release/owlet-rewriter`.

- [ ] **Step 3: Run all unit tests one more time as a regression check**

Run: `cd tools/rewriter && cargo test`
Expected: all tests pass (the count from Task 5: at least 24 across the modules).

- [ ] **Step 4: Manual smoke check against a running Ollama**

Pre-req: `ollama serve` running, `qwen3:8b` pulled.

Run:
```bash
printf 'i want python code for csv read' | ./tools/rewriter/target/release/owlet-rewriter
```
Expected: an improved English prompt printed to stdout within ~5s. The exact wording will vary by run.

Run:
```bash
printf '' | ./tools/rewriter/target/release/owlet-rewriter; echo "exit=$?"
```
Expected: no output, `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add tools/rewriter/src/main.rs
git commit -m "feat(rewriter): main entrypoint — stdin in, stdout out, exit codes per spec"
```

---

### Task 8: Shell smoke test

Mirror of the existing `tools/rewriter/test_stdin_smoke.sh` but pointed at the binary path the installer will produce.

**Files:**
- Create: `tools/rewriter/tests/smoke.sh`

- [ ] **Step 1: Create the smoke test**

```bash
#!/usr/bin/env bash
# Smoke test for owlet-rewriter (Rust binary).
# Asserts the binary consumes stdin (not clipboard) and writes to stdout.
# Pre-req: Ollama running, qwen3:8b pulled.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/../owlet-rewriter"

if [ ! -x "$BIN" ]; then
  echo "FAIL: binary not found or not executable at $BIN"
  echo "      Run install.sh, or:"
  echo "      (cd tools/rewriter && cargo build --release && cp target/release/owlet-rewriter ./owlet-rewriter)"
  exit 1
fi

# Test 1: stdin -> non-empty stdout, different from input
result="$(printf 'i want make python code for csv read' | "$BIN")"
if [ -n "$result" ] && [ "$result" != "i want make python code for csv read" ]; then
  echo "PASS: stdin -> stdout (got '$result')"
else
  echo "FAIL: empty or unchanged output"
  exit 1
fi

# Test 2: empty stdin -> no output, exit 0
empty="$(printf '' | "$BIN" || true)"
if [ -z "$empty" ]; then
  echo "PASS: empty stdin -> silent exit"
else
  echo "FAIL: expected empty output, got '$empty'"
  exit 1
fi

# Test 3: clipboard untouched
SENTINEL="OWLET_TEST_SENTINEL_$(date +%s)"
printf '%s' "$SENTINEL" | pbcopy
printf 'rewrite this' | "$BIN" >/dev/null
got="$(pbpaste)"
if [ "$got" = "$SENTINEL" ]; then
  echo "PASS: clipboard untouched"
else
  echo "FAIL: clipboard mutated (expected '$SENTINEL', got '$got')"
  exit 1
fi
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x tools/rewriter/tests/smoke.sh`

- [ ] **Step 3: Build the release binary into the stable path**

Run:
```bash
(cd tools/rewriter && cargo build --release) \
  && cp tools/rewriter/target/release/owlet-rewriter tools/rewriter/owlet-rewriter
```

- [ ] **Step 4: Run the smoke test**

Run: `./tools/rewriter/tests/smoke.sh`
Expected:
```
PASS: stdin -> stdout (got '...')
PASS: empty stdin -> silent exit
PASS: clipboard untouched
```

- [ ] **Step 5: Commit (binary stays gitignored — only the script is checked in)**

```bash
git add tools/rewriter/tests/smoke.sh
git commit -m "test(rewriter): shell smoke test for binary contract"
```

---

## Phase C — Build and install integration

### Task 9: Update `install.sh` to build the Rust binary

Replace the Python venv block with a `cargo` toolchain check and `cargo build --release`. The `defaults write co.greenpassport.owlet rewriterDirectory ...` line is unchanged — Swift continues to look for the binary at `<rewriterDirectory>/owlet-rewriter`.

**Files:**
- Modify: `install.sh` (block around lines 24–46)

- [ ] **Step 1: Read the current install.sh around the Python block**

Open `install.sh` and locate the section that runs from `if ! command -v python3` (around line 24) through `chmod +x "$HERE/tools/rewriter/rewrite_prompt.py"` (around line 45).

- [ ] **Step 2: Replace that block with the Rust block**

Replace lines ~24–45 (everything from the `python3` check up to and including the `chmod +x ... rewrite_prompt.py` line) with:

```bash
# ---------- Rust toolchain ----------
if ! command -v cargo >/dev/null 2>&1; then
  echo "ERROR: 'cargo' not found in PATH." >&2
  echo "       Install the Rust toolchain via:" >&2
  echo "         curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh" >&2
  echo "       Then re-run install.sh." >&2
  exit 1
fi

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
```

Also remove the now-unused variable at the top of the file: line 11 (`VENV="$HERE/tools/rewriter/.venv"`). Search for any other reference to `$VENV` and confirm none remain.

- [ ] **Step 3: Confirm no broken references**

Run: `grep -n VENV install.sh || echo "no VENV references"`
Expected: `no VENV references`.

Run: `grep -n rewrite_prompt.py install.sh || echo "no script references"`
Expected: `no script references`.

- [ ] **Step 4: Test the install script end-to-end (manual)**

This is a destructive test (rebuilds the app). Skip in subagent runs; run yourself when reviewing.

Run: `./install.sh`
Expected: prints `==> Building owlet-rewriter (Rust, release)`, no Python/venv mention, exits 0.

- [ ] **Step 5: Commit**

```bash
git add install.sh
git commit -m "build(installer): replace python venv with cargo build for owlet-rewriter"
```

---

### Task 10: Update `RewriterFlow.swift` spawn paths

Two-line change. Swift no longer launches `python3`; it launches the Rust binary directly.

**Files:**
- Modify: `Owlet/Owlet/RewriterFlow.swift:29-37` (the `makeDefaultRewriter` function)

- [ ] **Step 1: Replace the function body**

Find this block in `Owlet/Owlet/RewriterFlow.swift`:

```swift
    private static func makeDefaultRewriter() -> Rewriting {
        let fallback = NSString(string: "~/repos/owlet/tools/rewriter").expandingTildeInPath
        let dir = UserDefaults.standard.string(forKey: "rewriterDirectory") ?? fallback
        return OllamaClient(
            executablePath: "\(dir)/.venv/bin/python3",
            arguments: ["\(dir)/rewrite_prompt.py"],
            timeoutSeconds: 30
        )
    }
```

Replace with:

```swift
    private static func makeDefaultRewriter() -> Rewriting {
        let fallback = NSString(string: "~/repos/owlet/tools/rewriter").expandingTildeInPath
        let dir = UserDefaults.standard.string(forKey: "rewriterDirectory") ?? fallback
        return OllamaClient(
            executablePath: "\(dir)/owlet-rewriter",
            arguments: [],
            timeoutSeconds: 30
        )
    }
```

Also update the doc-comment above that function (lines 23–28) to mention "Rust binary" instead of "Python rewriter":

Replace:

```swift
    /// Build the production OllamaClient using the rewriter directory written
    /// to UserDefaults by install.sh (`defaults write co.greenpassport.owlet
    /// rewriterDirectory ...`). Falls back to the legacy ~/repos/owlet path
    /// only when no default is set — useful for first-launch-without-install
    /// debugging, never expected in production.
```

With:

```swift
    /// Build the production OllamaClient spawning the `owlet-rewriter` Rust binary
    /// from the rewriter directory written to UserDefaults by install.sh
    /// (`defaults write co.greenpassport.owlet rewriterDirectory ...`).
    /// Falls back to the legacy ~/repos/owlet path only when no default is set —
    /// useful for first-launch-without-install debugging, never expected in production.
```

- [ ] **Step 2: Also update `OllamaClient.swift:3` doc comment**

Open `Owlet/Owlet/OllamaClient.swift`. Replace the top doc comment (line 3):

```swift
/// Spawns the Python rewriter CLI and returns its stdout.
```

With:

```swift
/// Spawns the owlet-rewriter binary and returns its stdout.
```

The parameter doc on `executablePath` (lines 21–25) also mentions "Python interpreter" — update to "executable to spawn (the owlet-rewriter Rust binary in production, OR the fixture script in tests)".

- [ ] **Step 3: Verify Swift builds and all tests pass**

Run:
```bash
cd Owlet && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug \
    -derivedDataPath build test
```

Expected: build succeeds; all tests pass. The fixture-based tests (`OwletTests/Fixtures/fake-rewriter.sh`) keep working because `OllamaClient` still spawns an arbitrary executable.

- [ ] **Step 4: Commit**

```bash
git add Owlet/Owlet/RewriterFlow.swift Owlet/Owlet/OllamaClient.swift
git commit -m "feat(owlet): spawn owlet-rewriter Rust binary instead of python+script"
```

---

## Phase D — Cleanup and docs

### Task 11: Delete the Python rewriter

**Files:**
- Delete: `tools/rewriter/rewrite_prompt.py`
- Delete: `tools/rewriter/requirements.txt`
- Delete: `tools/rewriter/test_stdin_smoke.sh`
- Delete: `tools/rewriter/.venv/` if it exists locally

- [ ] **Step 1: Remove the files**

Run:
```bash
rm tools/rewriter/rewrite_prompt.py \
   tools/rewriter/requirements.txt \
   tools/rewriter/test_stdin_smoke.sh
rm -rf tools/rewriter/.venv
```

- [ ] **Step 2: Confirm nothing references them**

Run: `git grep -nE 'rewrite_prompt\.py|requirements\.txt|\.venv' || echo "no references"`
Expected: `no references` (or only references inside `docs/superpowers/` which are historical).

- [ ] **Step 3: Commit the deletions**

```bash
git add -A tools/rewriter/
git commit -m "chore(rewriter): drop python rewriter (replaced by owlet-rewriter binary)"
```

---

### Task 12: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update Prerequisites (lines 9–12)**

Replace:

```markdown
- macOS 14+ (tested on macOS 26.5 Apple Silicon)
- [Ollama](https://ollama.com/download)
- [Homebrew](https://brew.sh) — used to install xcodegen
- Xcode (full IDE — Command Line Tools alone are not enough)
```

With:

```markdown
- macOS 14+ (tested on macOS 26.5 Apple Silicon)
- [Ollama](https://ollama.com/download)
- [Rust toolchain](https://rustup.rs) — `cargo` is required to build `owlet-rewriter`
- [Homebrew](https://brew.sh) — used to install xcodegen
- Xcode (full IDE — Command Line Tools alone are not enough)
```

- [ ] **Step 2: Update the "The installer" list (lines 22–29)**

Replace item 2 (`Creates a Python venv at tools/rewriter/.venv/ and installs deps.`) with:

```markdown
2. Builds the `owlet-rewriter` Rust binary (`cargo build --release`).
```

- [ ] **Step 3: Update Customisation (lines 47–50)**

Replace:

```markdown
- **Change the model:** edit `MODEL = "qwen3:8b"` in `tools/rewriter/rewrite_prompt.py`.
- **Change the prompt:** edit `SYSTEM_PROMPT` in the same file.
- **Change the hotkey:** v0.2 hardcodes `fn+Ctrl+R`. Configurable hotkey is a v0.3 follow-up.
```

With:

```markdown
- **Change the model:** edit `const MODEL: &str = "qwen3:8b"` in `tools/rewriter/src/main.rs`, then re-run `./install.sh`.
- **Change the prompt:** edit `const SYSTEM_PROMPT` in the same file, then re-run `./install.sh`.
- **Change the hotkey:** v0.2 hardcodes `fn+Ctrl+R`. Configurable hotkey is a v0.3 follow-up.
```

- [ ] **Step 4: Update Project layout (lines 52–61)**

Replace the `tools/rewriter/` line:

```markdown
├── tools/rewriter/      # Python CLI (Ollama backend)
```

With:

```markdown
├── tools/rewriter/      # Rust CLI (Ollama backend, build with `cargo build --release`)
```

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs(readme): rust rewriter prerequisites + customisation pointers"
```

---

## Phase E — Validation

### Task 13: Run the validation checklist from spec §11

This is a manual checklist — not automated. Each item is a smoke test against the real installed app and a running Ollama. Do this on a machine with `qwen3:8b` already pulled.

**Files:** none modified. This task gates the PR.

- [ ] **Step 1: Fresh install**

Run: `./install.sh`
Expected: completes without error, prints "Install complete." If permissions need re-grant (TCC migration), follow the prompt.

- [ ] **Step 2: Binary in place**

Run: `ls -la tools/rewriter/owlet-rewriter`
Expected: exists, executable (`-rwxr-xr-x`).

- [ ] **Step 3: Smoke against real Ollama**

Run: `./tools/rewriter/tests/smoke.sh`
Expected: 3 PASS lines.

- [ ] **Step 4: Ollama-down error path**

In another terminal, kill Ollama: `pkill ollama` (or `ollama stop` if available).

Run:
```bash
printf 'rewrite me' | ./tools/rewriter/owlet-rewriter; echo "exit=$?"
```
Expected: stderr contains `Connection`, exit code 1.

Restart Ollama: `ollama serve &`

- [ ] **Step 5: Vietnamese-input live test (the language-preservation requirement)**

Open TextEdit, type a Vietnamese prompt, e.g.:
```
viet cho toi 1 doan code python doc file csv
```
Select all, press `fn+Ctrl+R`. Expected: popup shows an improved **Vietnamese** prompt, not English. If it returns English, capture the input + output and flag — that's the Phase 1 model-behavior question from spec §10.

- [ ] **Step 6: Short-prompt live test**

In TextEdit, select `write a poem`, press `fn+Ctrl+R`.
Expected: rewritten prompt stays short and open-ended. No invented `max 200 words` or specific subject. Acceptable: light structure like "Write a poem." or "Write a short poem." — not acceptable: a fully-fleshed creative-writing brief.

- [ ] **Step 7: Already-good prompt test**

In TextEdit, select a well-formed prompt like:
```
You are a senior Python engineer. Refactor the function below into smaller helpers, keeping behavior identical. Return only the refactored code, no commentary.
```
Press `fn+Ctrl+R`. Expected: popup shows the "no changes" state (`PopupState.empty`) OR a minimal-change result. Not acceptable: aggressive restructuring or added preamble.

- [ ] **Step 8: All Swift tests pass**

Run:
```bash
cd Owlet && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug \
    -derivedDataPath build test
```
Expected: ` ** TEST SUCCEEDED **`.

- [ ] **Step 9: Open the PR**

If all the above pass, the work is ready to merge.

```bash
git push -u origin <branch>
gh pr create --title "feat(rewriter): rust port + L2 prompt redesign" \
  --body "$(cat <<'EOF'
## Summary
- Replace tools/rewriter/rewrite_prompt.py (Python + L1 grammar polish prompt) with tools/rewriter/owlet-rewriter (Rust + L2 structural prompt engineering, preserves input language).
- Drops the python3/venv/requests dependency stack from install.sh in favor of cargo build --release.
- Swift change is a 2-line spawn-path update in RewriterFlow.swift; OllamaClient and the rest of the app are untouched.

Design spec: docs/superpowers/specs/2026-05-28-rewriter-rust-port-design.md
Implementation plan: docs/superpowers/plans/2026-05-28-rewriter-rust-port.md

## Test plan
- [x] `cargo test` passes (unit tests for string cleaners, response parser, error phrasings, payload shape)
- [x] `tools/rewriter/tests/smoke.sh` passes (stdin/stdout contract, clipboard untouched)
- [x] Ollama-down → stderr contains "Connection", exit 1; Swift maps to .ollamaDown
- [x] Vietnamese input → Vietnamese rewrite (language preservation)
- [x] Short prompt ("write a poem") → stays open-ended
- [x] Already-good prompt → minimal or no changes
- [x] xcodebuild test passes
EOF
)"
```

---

## Appendix — Final `tools/rewriter/src/main.rs` shape

After Task 7 the file should look approximately like this (line counts approximate):

```
use std::io::{self, Read, Write};
use std::process::ExitCode;
use std::time::Duration;

const OLLAMA_URL: &str = ...
const MODEL: &str = "qwen3:8b";
const TIMEOUT_SECS: u64 = 30;
const SYSTEM_PROMPT: &str = r#" ... "#;     // ~40 lines

#[derive(Debug)]
enum RewriteError { ... }
impl RewriteError { fn stderr_message ... }

fn strip_think_blocks(input: &str) -> String { ... }
fn strip_wrapping_quotes(input: &str) -> String { ... }
fn clean_output(raw: &str) -> String { ... }
fn parse_response(body: &str) -> Result<String, RewriteError> { ... }
fn build_payload(prompt: &str) -> serde_json::Value { ... }
fn call_ollama(prompt: &str) -> Result<String, RewriteError> { ... }
fn run() -> Result<Option<String>, RewriteError> { ... }
fn main() -> ExitCode { ... }

#[cfg(test)]
mod tests { ... }                            // ~25 tests
```

Target total: ~250–300 LOC including the system prompt and tests.
