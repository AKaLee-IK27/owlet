# Clipboard-Aware Capture + Shimmer Loading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show source text with shimmer during loading, auto-detect clipboard content, and conditionally show Replace button only for AX-captured text.

**Architecture:** Three coordinated changes: (1) `AXBridge` tracks `NSPasteboard.changeCount` and checks it before falling back to Cmd+C, (2) `PopupState` carries `captureMethod` through `.loading` and `.result` states, (3) `ImprovePromptFloater` renders shimmer on loading text, shows Cancel during loading, and hides Replace for clipboard captures.

**Tech Stack:** Swift, SwiftUI, AppKit, NSPasteboard, ApplicationServices

---

## File Structure

| File | Responsibility |
|------|---------------|
| `Owlet/Owlet/AXBridge.swift` | Add `lastOwletChangeCount` tracking, clipboard freshness check before Cmd+C |
| `Owlet/Owlet/PopupState.swift` | Add `captureMethod: SelectionSnapshot.CaptureMethod` to `.loading` and `.result` cases |
| `Owlet/Owlet/RewriterFlow.swift` | Pass `snap.captureMethod` into `.loading` and `.result` states |
| `Owlet/Owlet/Views/ImprovePromptFloater.swift` | Shimmer overlay on loading text, Cancel button during loading, conditional Replace |
| `Owlet/OwletTests/RewriterFlowTests.swift` | Test clipboard capture → no Replace, AX capture → Replace |
| `Owlet/OwletTests/PopupStateTests.swift` | Test `.loading` and `.result` with captureMethod |

---

### Task 1: Add `captureMethod` to `.loading` and `.result` in PopupState

**Files:**
- Modify: `Owlet/Owlet/PopupState.swift`
- Test: `Owlet/OwletTests/PopupStateTests.swift`

- [ ] **Step 1: Update PopupState enum to carry captureMethod**

Modify `PopupState.swift` to add `captureMethod: SelectionSnapshot.CaptureMethod` to the `.loading` and `.result` cases:

```swift
enum PopupState: Equatable {
    case loading(sourceText: String, isLong: Bool, captureMethod: SelectionSnapshot.CaptureMethod = .ax)
    case result(original: String, rewritten: String, segments: [DiffSegment]?, canReplace: Bool, captureMethod: SelectionSnapshot.CaptureMethod = .ax)
    case empty(text: String)
    case error(ErrorKind)
}
```

The default value `.ax` preserves backward compatibility for any code that constructs these cases without the new parameter (e.g., previews, tests).

- [ ] **Step 2: Update PopupStateTests to verify captureMethod carriers**

Add tests to `PopupStateTests.swift`:

```swift
func test_loading_carriesCaptureMethod_ax() {
    let s = PopupState.loading(sourceText: "hello", isLong: false, captureMethod: .ax)
    if case .loading(_, _, let method) = s { XCTAssertEqual(method, .ax) } else { XCTFail() }
}

func test_loading_carriesCaptureMethod_clipboard() {
    let s = PopupState.loading(sourceText: "hello", isLong: false, captureMethod: .clipboardFallback)
    if case .loading(_, _, let method) = s { XCTAssertEqual(method, .clipboardFallback) } else { XCTFail() }
}

func test_result_carriesCaptureMethod_clipboard() {
    let s = PopupState.result(original: "x", rewritten: "y", segments: nil, canReplace: true, captureMethod: .clipboardFallback)
    if case .result(_, _, _, _, let method) = s { XCTAssertEqual(method, .clipboardFallback) } else { XCTFail() }
}
```

- [ ] **Step 3: Run tests to verify**

Run: `cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' -only-testing:OwletTests/PopupStateTests`
Expected: All PopupStateTests pass.

---

### Task 2: Track clipboard changeCount in ClipboardGuard + AXBridge

**Files:**
- Modify: `Owlet/Owlet/ClipboardGuard.swift`
- Modify: `Owlet/Owlet/AXBridge.swift`

- [ ] **Step 1: Add changeCount tracking to ClipboardGuard**

Add to `ClipboardGuard.swift`:

```swift
/// The last-known pasteboard changeCount after an Owlet-initiated write.
/// Used by AXBridge to detect whether the clipboard was modified externally
/// (e.g., by Ghostty auto-copy, user Cmd+C) since Owlet last touched it.
private(set) var lastOwletChangeCount: Int = 0

/// Record the current pasteboard changeCount after an Owlet write.
func recordOwletChangeCount(_ count: Int) {
    lock.lock()
    defer { lock.unlock() }
    lastOwletChangeCount = count
}

/// Check whether the clipboard has been modified externally since Owlet
/// last wrote to it. Returns true if the current changeCount differs
/// from the last Owlet-recorded count.
func hasExternalClipboardChange() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return NSPasteboard.general.changeCount != lastOwletChangeCount
}
```

- [ ] **Step 2: Record changeCount after every Owlet clipboard write in ClipboardGuard**

In `performRestore()`, after writing to the pasteboard, record the new changeCount:

```swift
private func performRestore() {
    lock.lock()
    defer { lock.unlock() }
    guard let original = pendingOriginal else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(original, forType: .string)
    lastOwletChangeCount = pb.changeCount  // ADD THIS LINE
    pendingOriginal = nil
    pendingRestoreWorkItem = nil
}
```

- [ ] **Step 3: Add clipboard freshness check to AXBridge.capture()**

In `AXBridge.swift`, modify the `capture()` method. Before the `swiftCmdCCapture()` fallback, check if the clipboard already has fresh external content:

Replace the section starting at line 66 (`// Fallback: synthesize Cmd+C...`) with:

```swift
// Fallback: check if clipboard has fresh external content (e.g., Ghostty auto-copy, user Cmd+C).
if ClipboardGuard.shared.hasExternalClipboardChange(),
   let text = NSPasteboard.general.string(forType: .string),
   !text.isEmpty {
    return .captured(SelectionSnapshot(
        text: text,
        sourceAppBundleID: focus?.appBundleID ?? "",
        focusedElement: focus?.focusedElement,
        captureMethod: .clipboardFallback
    ))
}

// Clipboard is stale or empty — synthesize Cmd+C to capture the selection.
ClipboardGuard.shared.snapshotBeforeOverwrite()
if let text = swiftCmdCCapture() {
    // 5 s gives the popup plenty of time to consume the clipboard
    // before we restore the original underneath it.
    ClipboardGuard.shared.scheduleRestore(after: 5.0)
    ClipboardGuard.shared.recordOwletChangeCount(NSPasteboard.general.changeCount)
    return .captured(SelectionSnapshot(
        text: text,
        sourceAppBundleID: focus?.appBundleID ?? "",
        focusedElement: focus?.focusedElement,
        captureMethod: .clipboardFallback
    ))
}
```

Also record the changeCount on the failure path restore:

After `ClipboardGuard.shared.scheduleRestore(after: 0.5)` on line 85, add:
```swift
ClipboardGuard.shared.recordOwletChangeCount(NSPasteboard.general.changeCount)
```

- [ ] **Step 4: Record changeCount after replace clipboard writes in RewriterFlow**

In `RewriterFlow.swift`, `handleReplace()` method (line 196-198), after writing to clipboard:

```swift
NSPasteboard.general.clearContents()
NSPasteboard.general.setString(rewritten, forType: .string)
ClipboardGuard.shared.recordOwletChangeCount(NSPasteboard.general.changeCount)  // ADD THIS
popup.hide()
```

And in `handleCopy()` method (line 204-205):

```swift
NSPasteboard.general.clearContents()
NSPasteboard.general.setString(rewritten, forType: .string)
ClipboardGuard.shared.recordOwletChangeCount(NSPasteboard.general.changeCount)  // ADD THIS
```

- [ ] **Step 5: Run tests to verify**

Run: `cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS'`
Expected: All tests pass.

---

### Task 3: Pass captureMethod through RewriterFlow state machine

**Files:**
- Modify: `Owlet/Owlet/RewriterFlow.swift`
- Test: `Owlet/OwletTests/RewriterFlowTests.swift`

- [ ] **Step 1: Update .loading state to carry captureMethod**

In `RewriterFlow.swift`, line 62-63, change:

```swift
// FROM:
let isLong = snap.text.count > Self.inputSoftWarn
setState(.loading(sourceText: snap.text, isLong: isLong))

// TO:
let isLong = snap.text.count > Self.inputSoftWarn
setState(.loading(sourceText: snap.text, isLong: isLong, captureMethod: snap.captureMethod))
```

- [ ] **Step 2: Update .result state to carry captureMethod**

In `RewriterFlow.swift`, lines 105-108, change:

```swift
// FROM:
setState(.result(original: snap.text,
                  rewritten: rewritten,
                  segments: collapse ? nil : diff.segments,
                  canReplace: canReplace))

// TO:
setState(.result(original: snap.text,
                  rewritten: rewritten,
                  segments: collapse ? nil : diff.segments,
                  canReplace: canReplace,
                  captureMethod: snap.captureMethod))
```

- [ ] **Step 3: Update existing tests to pass captureMethod**

In `RewriterFlowTests.swift`, all existing tests use the default `.ax` parameter so they should compile without changes (thanks to the default value in PopupState). Verify by running tests.

- [ ] **Step 4: Add test for clipboard capture → result carries clipboardFallback**

Add to `RewriterFlowTests.swift`:

```swift
@MainActor
func test_clipboardCapture_resultCarriesClipboardFallbackMethod() async {
    let ax = MockAX()
    ax.outcome = .captured(SelectionSnapshot(
        text: "terminal output",
        sourceAppBundleID: "com.apple.Terminal",
        focusedElement: nil,
        captureMethod: .clipboardFallback
    ))
    let rewriter = MockRewriter()
    rewriter.response = .success("Rewritten terminal output.")
    let flow = RewriterFlow(ax: ax, rewriter: rewriter, popup: PopupWindowController())
    await flow.start()
    if case .result(_, _, _, _, let method) = flow.lastObservedState {
        XCTAssertEqual(method, .clipboardFallback)
    } else {
        XCTFail("expected .result, got \(String(describing: flow.lastObservedState))")
    }
}
```

- [ ] **Step 5: Run tests to verify**

Run: `cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS' -only-testing:OwletTests/RewriterFlowTests`
Expected: All RewriterFlowTests pass.

---

### Task 4: Shimmer loading text + Cancel button + conditional Replace in ImprovePromptFloater

**Files:**
- Modify: `Owlet/Owlet/Views/ImprovePromptFloater.swift`

- [ ] **Step 1: Add ShimmerText view**

Add a new private struct at the bottom of `ImprovePromptFloater.swift` (before the previews):

```swift
/// Renders text with an animated shimmer gradient overlay, so the user
/// can read their source text while visually seeing that processing is underway.
private struct ShimmerText: View {
    let text: String
    @State private var shimmerPhase: CGFloat = -1

    var body: some View {
        ZStack(alignment: .leading) {
            // Base text — slightly muted
            Text(text)
                .font(OwletDesign.displayItalic(size: 17))
                .lineSpacing(17 * 0.5)
                .foregroundStyle(OwletDesign.fg.opacity(0.5))
                .textSelection(.enabled)

            // Shimmer overlay — sweeps left to right
            Text(text)
                .font(OwletDesign.displayItalic(size: 17))
                .lineSpacing(17 * 0.5)
                .foregroundStyle(
                    LinearGradient(
                        colors: [OwletDesign.fgSubtle, OwletDesign.fg, OwletDesign.fgSubtle],
                        startPoint: UnitPoint(x: shimmerPhase, y: 0),
                        endPoint: UnitPoint(x: shimmerPhase + 0.5, y: 0)
                    )
                )
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                shimmerPhase = 1.5
            }
        }
    }
}
```

- [ ] **Step 2: Update loading output to show shimmer text instead of skeletons**

Replace the `.loading` case in the `output` computed property (lines 94-99):

```swift
// FROM:
case .loading:
    VStack(alignment: .leading, spacing: 9) {
        SkeletonLine(width: 0.94, delay: 0)
        SkeletonLine(width: 0.86, delay: 0.12)
        SkeletonLine(width: 0.72, delay: 0.24)
    }
    .frame(minHeight: 100, alignment: .top)

// TO:
case .loading(let sourceText, _, _):
    ScrollView(.vertical, showsIndicators: false) {
        ShimmerText(text: sourceText)
    }
    .frame(maxHeight: 220)
```

- [ ] **Step 3: Show Cancel button during loading**

Update `shouldShowActions` to return `true` for loading:

```swift
// FROM:
private var shouldShowActions: Bool {
    switch state {
    case .loading: return false
    case .result, .empty, .error: return true
    }
}

// TO:
private var shouldShowActions: Bool {
    switch state {
    case .loading, .result, .empty, .error: return true
    }
}
```

- [ ] **Step 4: Add Cancel button to loading actions**

Update the `.loading` case in the `actions` computed property (lines 187-188):

```swift
// FROM:
case .loading:
    EmptyView()

// TO:
case .loading:
    HStack(spacing: 4) {
        GhostButton(label: "Cancel", action: onCancel)
        Spacer(minLength: 0)
    }
```

- [ ] **Step 5: Conditionally show Replace button based on captureMethod**

Update the `.result` case in the `actions` computed property (lines 190-196):

```swift
// FROM:
case .result(_, _, _, let canReplace):
    HStack(spacing: 4) {
        PrimaryButton(label: "Replace", enabled: canReplace, action: onReplace)
        GhostButton(label: "Try again", action: onRetry)
        Spacer(minLength: 0)
        CopyButton(action: onCopy)
    }

// TO:
case .result(_, _, _, let canReplace, let captureMethod):
    HStack(spacing: 4) {
        if captureMethod == .ax {
            PrimaryButton(label: "Replace", enabled: canReplace, action: onReplace)
        }
        GhostButton(label: "Try again", action: onRetry)
        Spacer(minLength: 0)
        CopyButton(action: onCopy)
    }
```

- [ ] **Step 6: Update previews to reflect new state shapes**

Update the `#Preview("loading")` at the bottom of the file:

```swift
// FROM:
#Preview("loading") {
    ImprovePromptFloater(
        state: .loading(sourceText: "anything", isLong: false),
        onReplace: {}, onCopy: {}, onCancel: {}, onRetry: {})
    .padding(40)
    .background(OwletDesign.Sage.s800)
}

// TO:
#Preview("loading") {
    ImprovePromptFloater(
        state: .loading(sourceText: "write me a blog post about AI", isLong: false, captureMethod: .ax),
        onReplace: {}, onCopy: {}, onCancel: {}, onRetry: {})
    .padding(40)
    .background(OwletDesign.Sage.s800)
}
```

Update the `#Preview("ready")` to include captureMethod:

```swift
// FROM:
state: .result(
    original: "write me a blog post about AI",
    rewritten: "Write a 600-word blog post...",
    segments: nil,
    canReplace: true),

// TO:
state: .result(
    original: "write me a blog post about AI",
    rewritten: "Write a 600-word blog post for software engineers about practical uses of local LLMs in daily development workflows. Keep the tone pragmatic, with one concrete example per use case.",
    segments: nil,
    canReplace: true,
    captureMethod: .ax),
```

Add a new preview for clipboard-captured result (no Replace button):

```swift
#Preview("clipboard result (no Replace)") {
    ImprovePromptFloater(
        state: .result(
            original: "ls -la | grep foo",
            rewritten: "find . -name '*foo*' -ls",
            segments: nil,
            canReplace: true,
            captureMethod: .clipboardFallback),
        onReplace: {}, onCopy: {}, onCancel: {}, onRetry: {})
    .padding(40)
    .background(OwletDesign.Sage.s800)
}
```

- [ ] **Step 7: Run Swift build to verify compilation**

Run: `cd Owlet && xcodebuild -project Owlet.xcodeproj -scheme Owlet -configuration Debug -destination 'platform=macOS' build`
Expected: Build succeeds with no errors.

---

### Task 5: Run full test suite and verify

**Files:**
- All modified files

- [ ] **Step 1: Run full test suite**

Run: `cd Owlet && xcodebuild test -project Owlet.xcodeproj -scheme Owlet -destination 'platform=macOS'`
Expected: All tests pass. Note any pre-existing failures unrelated to these changes.

- [ ] **Step 2: Run Rust tests (unchanged, but verify no regression)**

Run: `cd tools/rewriter && cargo test`
Expected: All Rust tests pass.

- [ ] **Step 3: Commit**

```bash
git add Owlet/Owlet/AXBridge.swift \
        Owlet/Owlet/ClipboardGuard.swift \
        Owlet/Owlet/PopupState.swift \
        Owlet/Owlet/RewriterFlow.swift \
        Owlet/Owlet/Views/ImprovePromptFloater.swift \
        Owlet/OwletTests/PopupStateTests.swift \
        Owlet/OwletTests/RewriterFlowTests.swift
git commit -m "feat: clipboard-aware capture, shimmer loading, conditional Replace"
```
