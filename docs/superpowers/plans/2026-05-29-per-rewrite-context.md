# Per-Rewrite Context (feat-008) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user re-run a rewrite with a free-text note ("for my boss", "keep it short"), surfaced through the existing — currently decorative — "Add context" mode chip, without slowing the instant first rewrite.

**Architecture:** The first rewrite stays instant and context-free. The `.result` popup's "Add context" chip reveals a text field + Refine button; Refine re-runs the rewrite on the *stored* source text (no AX re-capture) with the note injected. The note travels Swift → `--context` flag → Rust, which prepends a delimited block to the user message (single system message preserved).

**Tech Stack:** SwiftUI/AppKit (macOS), Rust rewriter.

**Depends on feat-007** being merged first (both touch `run()` / the Rust pipeline). Implement after feat-007.

---

## File structure

| File | Responsibility |
|------|----------------|
| `tools/rewriter/src/main.rs` | Parse `--context`; inject a `[CONTEXT]` block into the user message; system-prompt rule. |
| `Owlet/Owlet/OllamaClient.swift` | `Rewriting.rewrite(_:context:)` requirement + a `rewrite(_:)` convenience default; per-call `--context` arg assembly. |
| `Owlet/Owlet/RewriterFlow.swift` | Extract `performRewrite(source:captureMethod:context:)`; store `lastSourceText`/`lastCaptureMethod`; add `refine(context:)` and `retry()`. |
| `Owlet/Owlet/Views/ImprovePromptFloater.swift` | `onRefine` callback; "Add context" chip reveals a `TextField` (`@FocusState`) + Refine; render only that chip for v0.4. |
| `Owlet/Owlet/PopupWindowController.swift` | `becomesKeyOnlyIfNeeded`; scope the app-switch dismiss observer to ignore Owlet itself. |
| `Owlet/OwletTests/RewriterFlowTests.swift` | Update `MockRewriter` to the 2-arg signature; add refine tests. |
| `feature_list.json`, `README.md` | feat-008 entry + focus-path smoke steps. |

**Decisions locked in from the spec:**
- The other four chips (clarify/structured/examples/compact) are **out of scope**: render only "Add context" for v0.4; leave `enum ImproveMode` intact for the future `--mode` feature.
- The popup is a `.nonactivatingPanel` never made key — a `TextField` needs `becomesKeyOnlyIfNeeded = true` and must take key focus *without activating Owlet*, else the `object: nil` app-switch dismiss self-fires. This is the primary risk and is covered by a mandatory smoke step (no unit test reaches it).

---

# Part A — Rust: `--context` flag

### Task 1: Parse `--context` (refactor `parse_model_arg` → `parse_args`)

**Files:**
- Modify: `tools/rewriter/src/main.rs:9-25` (`parse_model_arg`) and its tests at `:396-418`

- [ ] **Step 1: Replace the four existing `parse_model_arg_*` tests**

In `mod tests`, replace the block of `parse_model_arg_*` tests with:

```rust
#[test]
fn parse_args_returns_model_when_present() {
    let args = vec!["owlet-rewriter".to_string(), "--model".to_string(), "llama3.1:8b".to_string()];
    let parsed = parse_args(&args).unwrap();
    assert_eq!(parsed.model, "llama3.1:8b");
    assert_eq!(parsed.context, None);
}

#[test]
fn parse_args_defaults_model_when_absent() {
    let parsed = parse_args(&["owlet-rewriter".to_string()]).unwrap();
    assert_eq!(parsed.model, "qwen3:8b");
}

#[test]
fn parse_args_returns_context_when_present() {
    let args = vec!["owlet-rewriter".to_string(), "--context".to_string(), "for my boss".to_string()];
    assert_eq!(parse_args(&args).unwrap().context, Some("for my boss".to_string()));
}

#[test]
fn parse_args_model_and_context_together() {
    let args = vec![
        "owlet-rewriter".to_string(), "--model".to_string(), "m".to_string(),
        "--context".to_string(), "c".to_string(),
    ];
    let parsed = parse_args(&args).unwrap();
    assert_eq!(parsed.model, "m");
    assert_eq!(parsed.context, Some("c".to_string()));
}

#[test]
fn parse_args_errors_when_flag_has_no_value() {
    assert!(parse_args(&["owlet-rewriter".to_string(), "--context".to_string()]).is_err());
}

#[test]
fn parse_args_errors_on_unknown_flag() {
    assert!(parse_args(&["owlet-rewriter".to_string(), "--nope".to_string(), "x".to_string()]).is_err());
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `(cd tools/rewriter && cargo test parse_args)`
Expected: FAIL — `cannot find function parse_args` / `struct Args`.

- [ ] **Step 3: Replace `parse_model_arg` with `parse_args` + `Args`**

Replace `main.rs:9-25` with:

```rust
struct Args {
    model: String,
    context: Option<String>,
}

fn parse_args(args: &[String]) -> Result<Args, String> {
    // Tiny hand-rolled parser — clap would be overkill for two flags.
    let mut i = 1;
    let mut model: Option<String> = None;
    let mut context: Option<String> = None;
    while i < args.len() {
        match args[i].as_str() {
            "--model" => {
                let v = args.get(i + 1).ok_or_else(|| "--model requires a value".to_string())?;
                model = Some(v.clone());
                i += 2;
            }
            "--context" => {
                let v = args.get(i + 1).ok_or_else(|| "--context requires a value".to_string())?;
                context = Some(v.clone());
                i += 2;
            }
            other => return Err(format!("unknown argument: {other}")),
        }
    }
    Ok(Args {
        model: model.unwrap_or_else(|| DEFAULT_MODEL.to_string()),
        context,
    })
}
```

- [ ] **Step 4: Update the `run` call sites (keep the crate compiling)**

In `run`, replace the parse line (`main.rs:192`):

```rust
    let model = parse_model_arg(args).map_err(RewriteError::Parse)?;
```

with:

```rust
    let parsed = parse_args(args).map_err(RewriteError::Parse)?;
```

and update the `call_ollama` call (still 2-arg at this point — feat-007 left it as `call_ollama(&masked, &model)`) to use the new binding:

```rust
    let raw = call_ollama(&masked, &parsed.model)?;
```

(`parsed.context` is consumed in Task 2.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `(cd tools/rewriter && cargo test)`
Expected: PASS — crate compiles; the 6 `parse_args` tests pass alongside the existing suite.

- [ ] **Step 6: Commit**

```bash
git add tools/rewriter/src/main.rs
git commit -m "feat(rewriter): parse --context flag (feat-008)"
```

---

### Task 2: Inject context into the user message

**Files:**
- Modify: `tools/rewriter/src/main.rs` — `SYSTEM_PROMPT` (`:27-67`) and `build_payload` (`:140-151`) and its tests (`:374-394`)

- [ ] **Step 1: Update the two existing `build_payload_*` tests and add a context test**

Replace `build_payload_has_expected_shape` and `build_payload_uses_provided_model` with versions passing the new `context` arg, and add a third test:

```rust
#[test]
fn build_payload_has_expected_shape() {
    let p = build_payload("rewrite me", "qwen3:8b", None);
    assert_eq!(p["model"], "qwen3:8b");
    assert_eq!(p["stream"], false);
    assert_eq!(p["think"], false);
    assert_eq!(p["options"]["temperature"], 0.2);
    let msgs = p["messages"].as_array().expect("messages array");
    assert_eq!(msgs.len(), 2);
    assert_eq!(msgs[0]["role"], "system");
    assert_eq!(msgs[1]["role"], "user");
    assert_eq!(msgs[1]["content"], "rewrite me");
    let sys_text = msgs[0]["content"].as_str().unwrap();
    assert!(sys_text.contains("prompt engineering assistant"));
}

#[test]
fn build_payload_uses_provided_model() {
    let p = build_payload("hi", "llama3.1:8b", None);
    assert_eq!(p["model"], "llama3.1:8b");
}

#[test]
fn build_payload_prepends_context_block_to_user_message() {
    let p = build_payload("rewrite me", "qwen3:8b", Some("for my boss"));
    let content = p["messages"][1]["content"].as_str().unwrap();
    assert!(content.contains("[CONTEXT]"));
    assert!(content.contains("for my boss"));
    assert!(content.trim_end().ends_with("rewrite me"));
    // Still exactly one system message.
    assert_eq!(p["messages"].as_array().unwrap().len(), 2);
}

#[test]
fn build_payload_blank_context_is_ignored() {
    let p = build_payload("rewrite me", "qwen3:8b", Some("   "));
    assert_eq!(p["messages"][1]["content"], "rewrite me");
}
```

- [ ] **Step 2: Run to verify failure**

Run: `(cd tools/rewriter && cargo test build_payload)`
Expected: FAIL — arity mismatch / new test fails.

- [ ] **Step 3: Add the context rule to `SYSTEM_PROMPT`**

In `SYSTEM_PROMPT`, insert this section immediately before the final `# Output` section:

```text
# User-provided context
The user message may begin with a [CONTEXT]…[/CONTEXT] block. Treat it as guidance about audience, scope, tone, or constraints for this rewrite. Apply it. Never repeat, quote, or mention the context block in your output — rewrite only the draft that follows it.
```

- [ ] **Step 4: Update `build_payload`**

Replace `build_payload` (`:140-151`) with:

```rust
fn build_payload(prompt: &str, model: &str, context: Option<&str>) -> serde_json::Value {
    let user_content = match context {
        Some(ctx) if !ctx.trim().is_empty() => {
            format!("[CONTEXT]\n{ctx}\n[/CONTEXT]\n\n{prompt}")
        }
        _ => prompt.to_string(),
    };
    serde_json::json!({
        "model": model,
        "messages": [
            { "role": "system", "content": SYSTEM_PROMPT },
            { "role": "user",   "content": user_content },
        ],
        "stream": false,
        "think": false,
        "options": { "temperature": 0.2 }
    })
}
```

- [ ] **Step 5: Update `call_ollama` to take + forward context**

Change the `call_ollama` signature line (`:153`):

```rust
fn call_ollama(prompt: &str, model: &str, context: Option<&str>) -> Result<String, RewriteError> {
```

and its payload line:

```rust
    let payload = build_payload(prompt, model, context);
```

- [ ] **Step 6: Update `run` to pass context (makes the signature change atomic)**

In `run`, change the `call_ollama` call (which Task 1 left as `call_ollama(&masked, &parsed.model)`) to:

```rust
    let raw = call_ollama(&masked, &parsed.model, parsed.context.as_deref())?;
```

- [ ] **Step 7: Run the full Rust suite to verify everything passes**

Run: `(cd tools/rewriter && cargo test)`
Expected: PASS — crate compiles; the 4 `build_payload` tests pass alongside the full suite (`parse_args`, feat-007 masking, etc.).

- [ ] **Step 8: Commit**

```bash
git add tools/rewriter/src/main.rs
git commit -m "feat(rewriter): inject [CONTEXT] block end-to-end into Ollama call (feat-008)"
```

---

# Part B — Swift: protocol, flow, UI, window

### Task 3: `Rewriting.rewrite(_:context:)` + `OllamaClient`

**Files:**
- Modify: `Owlet/Owlet/OllamaClient.swift:36-124`
- Modify: `Owlet/OwletTests/RewriterFlowTests.swift:18-25` (MockRewriter)

- [ ] **Step 1: Update `MockRewriter` to the 2-arg signature + context capture (failing build)**

Replace `MockRewriter` (`RewriterFlowTests.swift:18-25`) with:

```swift
    final class MockRewriter: Rewriting, @unchecked Sendable {
        var response: Result<String, Error> = .success("rewritten")
        var callCount = 0
        var lastContext: String? = nil
        func rewrite(_ input: String, context: String?) async throws -> String {
            callCount += 1
            lastContext = context
            return try response.get()
        }
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `(cd Owlet && xcodegen generate && xcodebuild build -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS')`
Expected: FAIL — `OllamaClient` and the protocol still use the 1-arg form; type does not conform.

- [ ] **Step 3: Update the protocol + add a convenience default**

Replace the protocol block at the bottom of `OllamaClient.swift` (`:120-124`) with:

```swift
protocol Rewriting: Sendable {
    func rewrite(_ input: String, context: String?) async throws -> String
}

extension Rewriting {
    /// Convenience for the context-free fast path; keeps existing call sites working.
    func rewrite(_ input: String) async throws -> String {
        try await rewrite(input, context: nil)
    }
}

extension OllamaClient: Rewriting {}
```

- [ ] **Step 4: Update `OllamaClient.rewrite` to accept context and assemble args per-call**

Change the method signature (`:36`):

```swift
    func rewrite(_ input: String, context: String?) async throws -> String {
```

and immediately after `process.executableURL = …` (`:38`), replace the `process.arguments = arguments` line (`:39`) with:

```swift
        if let context, !context.isEmpty {
            process.arguments = arguments + ["--context", context]
        } else {
            process.arguments = arguments
        }
```

- [ ] **Step 5: Build to verify it passes**

Run: `(cd Owlet && xcodebuild build -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS')`
Expected: PASS. (If `OllamaClientTests.swift` calls `.rewrite(x)` directly, those still compile via the convenience default — no change needed.)

- [ ] **Step 6: Commit**

```bash
git add Owlet/Owlet/OllamaClient.swift Owlet/OwletTests/RewriterFlowTests.swift
git commit -m "feat: Rewriting.rewrite(_:context:) + per-call --context arg (feat-008)"
```

---

### Task 4: `RewriterFlow` — stored source, `refine`, `retry`

**Files:**
- Modify: `Owlet/Owlet/RewriterFlow.swift:17` (state), `:55-65` (start), `:108-134` (setState)
- Modify: `Owlet/OwletTests/RewriterFlowTests.swift` (add tests)

- [ ] **Step 1: Write the failing tests**

Add to `RewriterFlowTests`:

```swift
    @MainActor
    func test_refine_rewritesStoredText_withContext() async {
        let ax = MockAX()
        let bogus = unsafeBitCast(0, to: AXUIElement.self)
        ax.outcome = .captured(SelectionSnapshot(text: "the cat sat", sourceAppBundleID: "t",
                                        focusedElement: bogus, captureMethod: .ax))
        let rewriter = MockRewriter()
        rewriter.response = .success("the dog sat")
        let flow = RewriterFlow(ax: ax, rewriter: rewriter, popup: PopupWindowController())
        await flow.start()                       // stores "the cat sat"
        ax.outcome = .empty                      // selection now gone — refine must NOT re-capture
        rewriter.response = .success("the formal dog sat")
        await flow.refine(context: "make it formal")
        XCTAssertEqual(rewriter.lastContext, "make it formal")
        if case .result(let original, let new, _, _, _) = flow.lastObservedState {
            XCTAssertEqual(original, "the cat sat", "diff baseline stays the original source")
            XCTAssertEqual(new, "the formal dog sat")
        } else { XCTFail("expected .result, got \(String(describing: flow.lastObservedState))") }
    }

    @MainActor
    func test_retry_reusesStoredText_notReCapture() async {
        let ax = MockAX()
        let bogus = unsafeBitCast(0, to: AXUIElement.self)
        ax.outcome = .captured(SelectionSnapshot(text: "hello world", sourceAppBundleID: "t",
                                        focusedElement: bogus, captureMethod: .ax))
        let rewriter = MockRewriter()
        rewriter.response = .success("greetings world")
        let flow = RewriterFlow(ax: ax, rewriter: rewriter, popup: PopupWindowController())
        await flow.start()
        ax.outcome = .empty                      // selection gone
        await flow.retry()
        XCTAssertNil(rewriter.lastContext, "retry sends no context")
        if case .result = flow.lastObservedState {} else {
            XCTFail("retry should re-run from stored text, got \(String(describing: flow.lastObservedState))")
        }
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `(cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' -only-testing:OwletTests/RewriterFlowTests)`
Expected: FAIL — `value of type 'RewriterFlow' has no member 'refine'`/`retry`.

- [ ] **Step 3: Add stored properties**

After `RewriterFlow.swift:17` (`private var _currentFocusedElement: AXUIElement?`) add:

```swift
    private var lastSourceText: String = ""
    private var lastCaptureMethod: SelectionSnapshot.CaptureMethod = .ax
```

- [ ] **Step 4: Extract `performRewrite` and slim down `start`**

Replace `start()` body from the `_currentFocusedElement = snap.focusedElement` line through the end of the method (`RewriterFlow.swift:65`) so that `start` captures, stores, then delegates:

```swift
        _currentFocusedElement = snap.focusedElement
        lastSourceText = snap.text
        lastCaptureMethod = snap.captureMethod
        await performRewrite(source: snap.text, captureMethod: snap.captureMethod, context: nil)
    }

    /// Re-run the rewrite on already-captured text (refine after edit).
    func refine(context: String) async {
        await performRewrite(source: lastSourceText, captureMethod: lastCaptureMethod, context: context)
    }

    /// "Try again" — re-run from stored text, never re-capturing (the
    /// selection may be gone once the popup has focus).
    func retry() async {
        await performRewrite(source: lastSourceText, captureMethod: lastCaptureMethod, context: nil)
    }

    private func performRewrite(source: String,
                                captureMethod: SelectionSnapshot.CaptureMethod,
                                context: String?) async {
        if source.count > Self.inputHardLimit {
            setState(.error(.inputTooLong(charCount: source.count)))
            return
        }
        let isLong = source.count > Self.inputSoftWarn
        setState(.loading(sourceText: source, isLong: isLong, captureMethod: captureMethod))

        let rewrittenRaw: String
        do {
            rewrittenRaw = try await rewriter.rewrite(source, context: context)
        } catch OllamaClient.Failure.timeout {
            setState(.error(.timeout)); return
        } catch OllamaClient.Failure.emptyOutput {
            setState(.error(.emptyOutput)); return
        } catch OllamaClient.Failure.backendError(let msg) {
            if msg.localizedCaseInsensitiveContains("Connection") {
                setState(.error(.ollamaDown))
            } else {
                setState(.error(.backendUnavailable(message: msg)))
            }
            return
        } catch OllamaClient.Failure.launchFailed(let msg) {
            setState(.error(.backendUnavailable(message: msg))); return
        } catch {
            setState(.error(.backendUnavailable(message: "\(error)"))); return
        }

        let rewritten = CleanOutput.clean(rewrittenRaw)
        if rewritten.isEmpty {
            setState(.error(.emptyOutput)); return
        }
        if rewritten == source.trimmingCharacters(in: .whitespacesAndNewlines) {
            setState(.empty(text: rewritten)); return
        }

        let diff = DiffEngine.diff(source, rewritten)
        let collapse = DiffResult.shouldCollapse(removedRatio: diff.removedRatio)
        let canReplace = rewritten.count <= Self.outputHardLimit
        setState(.result(original: source,
                         rewritten: rewritten,
                         segments: collapse ? nil : diff.segments,
                         canReplace: canReplace,
                         captureMethod: captureMethod))
    }
```

> Note: the early `inputHardLimit` check that was *before* `setState(.loading)` in the old `start()` now lives inside `performRewrite`; the `test_inputTooLong_hardRejects` test still passes because `start` calls `performRewrite` which rejects before calling the rewriter.

- [ ] **Step 5: Route the popup's `onRetry`/`onRefine` to the new methods**

In `setState` (the non-screenshot `else` branch, `:122-133`), change the `ImprovePromptFloater` initializer's `onRetry` and add `onRefine`:

```swift
            popup.show(
                ImprovePromptFloater(
                    state: state,
                    onReplace: { [weak self] in self?.handleReplace() },
                    onCopy:    { [weak self] in self?.handleCopy() },
                    onCancel:  { [weak self] in self?.handleCancel() },
                    onRetry:   { Task { [weak self] in await self?.retry() } },
                    onRefine:  { ctx in Task { [weak self] in await self?.refine(context: ctx) } }
                ),
                anchorRect: Self.anchorRect(for: _currentFocusedElement),
                width: OwletDesign.Floater.width
            )
```

Also add `onRefine: { _ in }` to the `loadingScreenshot` branch's `ImprovePromptFloater(...)` initializer (`:111-118`) so both call sites compile.

- [ ] **Step 6: Run tests to verify they pass**

Run: `(cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' -only-testing:OwletTests/RewriterFlowTests)`
Expected: PASS — existing flow tests plus the 2 new ones. (Compiles once Task 5 adds `onRefine` to `ImprovePromptFloater`.)

- [ ] **Step 7: Commit**

```bash
git add Owlet/Owlet/RewriterFlow.swift Owlet/OwletTests/RewriterFlowTests.swift
git commit -m "feat: RewriterFlow refine()/retry() reuse stored source text (feat-008)"
```

---

### Task 5: Popup — "Add context" chip reveals the field

**Files:**
- Modify: `Owlet/Owlet/Views/ImprovePromptFloater.swift` — props (`:28-35`), body (`:36-49`), `modeChips` (`:178-191`), previews (`:585-640`)

- [ ] **Step 1: Add the `onRefine` callback + field state**

After the `onRetry` property (`:32`) add:

```swift
    let onRefine: (String) -> Void
```

Replace the `activeMode` state line (`:35`) with:

```swift
    @State private var showContextField = false
    @State private var contextText = ""
    @FocusState private var contextFocused: Bool
```

- [ ] **Step 2: Insert the context field into the body**

In `body`, replace the `modeChips` conditional block (`:43-45`) with:

```swift
            if case .result(_, _, _, _, _) = state {
                modeChips.padding(.bottom, showContextField ? 8 : 12)
                if showContextField {
                    contextField.padding(.bottom, 12)
                }
            }
```

- [ ] **Step 3: Replace `modeChips` to render only "Add context" and toggle the field**

Replace `modeChips` (`:178-191`) with:

```swift
    // MARK: Mode chips — v0.4 surfaces only "Add context" (others await --mode).
    private var modeChips: some View {
        HStack(spacing: 2) {
            ModeChip(mode: .context, active: showContextField) {
                showContextField.toggle()
                if showContextField {
                    // Defer so the field exists before we focus it.
                    DispatchQueue.main.async { contextFocused = true }
                } else {
                    contextText = ""
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, -6)
    }

    private var contextField: some View {
        HStack(spacing: 6) {
            TextField("Add context for this rewrite…", text: $contextText)
                .textFieldStyle(.plain)
                .font(OwletDesign.ui(size: 12, weight: .regular))
                .foregroundStyle(OwletDesign.fg)
                .focused($contextFocused)
                .onSubmit(submitRefine)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(OwletDesign.fg.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(OwletDesign.hairline, lineWidth: 1)
                )
            PrimaryButton(
                label: "Refine",
                enabled: !contextText.trimmingCharacters(in: .whitespaces).isEmpty,
                action: submitRefine
            )
        }
    }

    private func submitRefine() {
        let trimmed = contextText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onRefine(trimmed)
    }
```

- [ ] **Step 4: Update every preview to pass `onRefine`**

In each `#Preview` / preview initializer that constructs `ImprovePromptFloater(...)` (lines ~585-640), add `onRefine: { _ in }` alongside the other closures. Example:

```swift
    ImprovePromptFloater(state: .result(original: "a", rewritten: "b", segments: nil, canReplace: true),
        onReplace: {}, onCopy: {}, onCancel: {}, onRetry: {}, onRefine: { _ in })
```

- [ ] **Step 5: Build to verify it compiles**

Run: `(cd Owlet && xcodebuild build -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS')`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Owlet/Owlet/Views/ImprovePromptFloater.swift
git commit -m "feat: Add-context chip reveals refine field in popup (feat-008)"
```

---

### Task 6: Make the panel key-capable without activating Owlet

**Files:**
- Modify: `Owlet/Owlet/PopupWindowController.swift:34-44` (panel setup), `:104-113` (app-switch observer)

- [ ] **Step 1: Let only input-needing views take key**

In the panel-creation block, after `p.isFloatingPanel = true` (`:34`), add:

```swift
            p.becomesKeyOnlyIfNeeded = true   // text field can become key; buttons don't
```

This lets the `TextField` make the panel key on click while leaving the click-through behavior of buttons unchanged. A `.nonactivatingPanel` becomes key **without** activating the app, so the user's foreground app keeps its active status.

- [ ] **Step 2: Stop the app-switch observer from self-dismissing on Owlet's own activation**

Replace the `installAppSwitchDismiss` body (`:104-113`) with:

```swift
    private func installAppSwitchDismiss() {
        guard appSwitchObserver == nil else { return }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Ignore Owlet activating itself (e.g. when the context field
            // takes key focus) — only dismiss when ANOTHER app comes forward.
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == Bundle.main.bundleIdentifier { return }
            self?.hide()
        }
    }
```

- [ ] **Step 3: Build**

Run: `(cd Owlet && xcodebuild build -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS')`
Expected: PASS.

- [ ] **Step 4: Manual focus smoke (no unit test reaches this — REQUIRED)**

Install (`./install.sh`) and verify, in a real text field:
1. Trigger a rewrite → popup appears.
2. Click the **Add context** chip → field appears and **takes the caret**; typing produces characters (this is the dead-in-app trap from feat-005/006 — if typing does nothing, the panel isn't becoming key).
3. Press **Refine** (or Return) → rewrite re-runs with the context.
4. **Replace** still writes back into the original app's field.
5. Clicking **outside** the popup still dismisses it; clicking the field or typing does **not**.

- [ ] **Step 5: Commit**

```bash
git add Owlet/Owlet/PopupWindowController.swift
git commit -m "feat: popup takes key focus for context field without self-dismiss (feat-008)"
```

---

### Task 7: Evidence + README

**Files:**
- Modify: `feature_list.json`, `README.md`

- [ ] **Step 1: Add the README smoke steps**

Under the manual smoke-test checklist in `README.md`, add:

```markdown
- **Add context / Refine:** after a rewrite, click **Add context**, type a note (e.g. "make it formal"), press **Refine**. Confirm the field accepts keystrokes, the rewrite re-runs with the note applied, **Replace** still works, and clicking outside still dismisses.
```

- [ ] **Step 2: Add the feature_list.json entry**

```json
{
  "id": "feat-008",
  "name": "Per-rewrite context (refine after)",
  "description": "Result popup's 'Add context' chip reveals a free-text field + Refine; re-runs the rewrite on stored source text with the note injected via a --context flag and a [CONTEXT] block in the user message. Popup becomes key (becomesKeyOnlyIfNeeded) without self-dismiss. Spec: docs/superpowers/specs/2026-05-29-rewriter-options-design.md.",
  "dependencies": ["feat-007"],
  "status": "done",
  "evidence": ""
}
```

- [ ] **Step 3: Run the full suites and paste evidence**

Run:
```bash
(cd tools/rewriter && cargo test)
(cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS')
```
Paste the pass counts plus the result of the Task 6 manual focus smoke into the `evidence` field.

- [ ] **Step 4: Commit**

```bash
git add feature_list.json README.md
git commit -m "docs(feat-008): smoke steps + feature_list evidence"
```

---

## Self-review checklist (run before handing off)

- [ ] **Spec coverage:** `--context` parse (T1), `[CONTEXT]` injection end-to-end + single system message + never-echo rule (T2), protocol+client (T3), refine/retry-from-stored-text + diff-vs-original (T4), Add-context chip reveal + only-that-chip + `@FocusState` (T5), `becomesKeyOnlyIfNeeded` + no-self-dismiss + manual smoke (T6), evidence/README (T7).
- [ ] **Placeholder scan:** no TBD/TODO; every code step shows full code.
- [ ] **Type consistency:** `rewrite(_:context:)` everywhere; `performRewrite(source:captureMethod:context:)`; `onRefine: (String) -> Void` matches the `setState` and preview call sites; `parse_args`/`Args`/`build_payload(_,_,context)` consistent across Part A.
- [ ] **Cross-feature:** depends on feat-007 merged (shared `run()`); the masking pipeline and `--context` compose (mask operates on stdin, context is a flag).
- [ ] **Final gate:** `./init.sh` passes from a clean checkout.
