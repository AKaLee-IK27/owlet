import Foundation
import AppKit
import ApplicationServices

@MainActor
final class RewriterFlow {
    private let ax: AXBridging
    private let rewriter: Rewriting
    private let popup: PopupWindowController
    private let regionSelector: RegionSelectorController
    private let screenshotCapturer: ScreenshotCapturer
    private let visionClient: VisionClient

    /// Exposed for tests so they can assert the last state set on the popup.
    private(set) var lastObservedState: PopupState? = nil

    private var _currentFocusedElement: AXUIElement?
    private var lastSourceText: String = ""
    private var lastCaptureMethod: SelectionSnapshot.CaptureMethod = .ax

    init(ax: AXBridging = AXBridgeAdapter(),
         rewriter: Rewriting? = nil,
         popup: PopupWindowController = PopupWindowController(),
         regionSelector: RegionSelectorController = RegionSelectorController(),
         screenshotCapturer: ScreenshotCapturer = ScreenshotCapturer(),
         visionClient: VisionClient? = nil) {
        self.ax = ax
        self.popup = popup
        self.rewriter = rewriter ?? Self.makeDefaultRewriter()
        self.regionSelector = regionSelector
        self.screenshotCapturer = screenshotCapturer
        self.visionClient = visionClient ?? VisionClient(model: Preferences.shared.visionModel, timeoutSeconds: 60)
    }

    /// Build the production OllamaClient spawning the `owlet-rewriter` Rust binary
    /// from the rewriter directory written to UserDefaults by install.sh
    /// (`defaults write co.greenpassport.owlet rewriterDirectory ...`).
    /// Falls back to the legacy ~/repos/owlet path only when no default is set —
    /// useful for first-launch-without-install debugging, never expected in production.
    private static func makeDefaultRewriter() -> Rewriting {
        let fallback = NSString(string: "~/repos/owlet/tools/rewriter").expandingTildeInPath
        let dir = UserDefaults.standard.string(forKey: "rewriterDirectory") ?? fallback
        // Read the model lazily on each construction — picks up Settings changes
        // without needing a tap restart or notification subscription here.
        let model = Preferences.shared.model
        return OllamaClient(
            executablePath: "\(dir)/owlet-rewriter",
            arguments: ["--model", model],
            timeoutSeconds: 30
        )
    }

    private static let inputSoftWarn = 4_000
    private static let inputHardLimit = 16_000
    private static let outputHardLimit = 32_000

    func start() async {
        // 1) Capture
        let snap: SelectionSnapshot
        switch ax.capture() {
        case .captured(let s): snap = s
        case .passwordField:
            setState(.error(.passwordField)); return
        case .noFocus, .empty:
            setState(.error(.selectionEmpty)); return
        }
        _currentFocusedElement = snap.focusedElement
        lastSourceText = snap.text
        lastCaptureMethod = snap.captureMethod
        await performRewrite(source: snap.text, captureMethod: snap.captureMethod, context: nil)
    }

    /// Re-run the rewrite on already-captured text (refine after edit).
    func refine(context: String) async {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { await retry(); return }
        await performRewrite(source: lastSourceText, captureMethod: lastCaptureMethod, context: trimmed)
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

    func startFromScreenshot() async {
        // 1. Region selection
        guard let region = await regionSelector.selectRegion() else { return }

        // 2. Capture
        guard let imageData = await screenshotCapturer.capture(region: region) else {
            setState(.error(.selectionUnreadable))
            return
        }

        // 3. Loading state
        setState(.loadingScreenshot)

        // 4. Vision model
        do {
            let rewritten = try await visionClient.rewrite(imageData: imageData)
            setState(.result(
                original: "",
                rewritten: rewritten,
                segments: nil,
                canReplace: false
            ))
        } catch VisionClient.Failure.modelNotFound(let model) {
            setState(.error(.backendUnavailable(message: "Vision model '\(model)' not found. Run `ollama pull \(model)`")))
        } catch VisionClient.Failure.timeout {
            setState(.error(.timeout))
        } catch VisionClient.Failure.emptyOutput {
            setState(.error(.noTextInImage))
        } catch VisionClient.Failure.backendError(let msg) {
            if msg.localizedCaseInsensitiveContains("Connection") {
                setState(.error(.ollamaDown))
            } else {
                setState(.error(.backendUnavailable(message: msg)))
            }
        } catch VisionClient.Failure.launchFailed(let msg) {
            setState(.error(.backendUnavailable(message: msg)))
        } catch {
            setState(.error(.backendUnavailable(message: "\(error)")))
        }
    }

    private func setState(_ state: PopupState) {
        lastObservedState = state
        if case .loadingScreenshot = state {
            popup.show(
                ImprovePromptFloater(
                    state: .loading(sourceText: "Analyzing screenshot…", isLong: false),
                    onReplace: {},
                    onCopy: {},
                    onCancel: { [weak self] in self?.handleCancel() },
                    onRetry: { Task { [weak self] in await self?.startFromScreenshot() } },
                    onRefine: { _ in }
                ),
                anchorRect: nil,
                width: OwletDesign.Floater.width
            )
        } else {
            // NOTE: popup.show() installs a fresh NSHostingView, so all view-local
            // @State in ImprovePromptFloater (showContextField, contextText) resets
            // on every setState. Intended — each state gets a clean view. Don't rely
            // on @State surviving a setState; lift any cross-state value into RewriterFlow.
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
        }
    }

    /// Compute the popup's screen-coord anchor rect.
    ///
    /// **AX path** (TextEdit / Pages / Notes / any AX-cooperative app):
    /// read the focused element's frame from the Accessibility API. AX gives
    /// us window-coords with origin at the top-left; we flip Y into NSScreen's
    /// bottom-left coordinate space so PopupWindowController.position(near:)
    /// can lay the popup below it.
    ///
    /// **Clipboard-fallback path** (Electron / Chrome / Terminal — no AX
    /// element): anchor on the mouse cursor instead. Not ideal (the rewrite
    /// happens in a text field that isn't necessarily where the cursor is),
    /// but better than screen-center and good enough until per-app coord
    /// hacks land.
    ///
    /// Returns nil when even the mouse fallback can't be resolved, which
    /// causes PopupWindowController to center the panel — the v0.3 behavior.
    private static func anchorRect(for element: AXUIElement?) -> NSRect? {
        if let element = element,
           let frame = screenFrame(of: element) {
            return frame
        }
        // No usable AX rect — fall back to the mouse cursor location. NSEvent
        // already gives bottom-left/Y-up screen coords, so no flip needed.
        let mouse = NSEvent.mouseLocation
        guard mouse != .zero else { return nil }
        return NSRect(x: mouse.x, y: mouse.y, width: 0, height: 0)
    }

    /// Read an AXUIElement's frame and convert to NSScreen coordinates.
    /// Returns nil if either AX attribute is missing or if the coordinate
    /// flip fails (no primary screen).
    private static func screenFrame(of element: AXUIElement) -> NSRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posValue = posValue, let sizeValue = sizeValue,
              CFGetTypeID(posValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        let gotPos = AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
        let gotSize = AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        guard gotPos, gotSize, size.width > 0, size.height > 0 else { return nil }

        // AX uses top-left origin in the global coordinate space (origin at
        // the primary display's top-left). NSScreen uses bottom-left origin.
        // Flip via the primary screen's height — `NSScreen.screens.first` is
        // the primary display on macOS.
        guard let primary = NSScreen.screens.first else { return nil }
        let nsY = primary.frame.height - pos.y - size.height
        return NSRect(x: pos.x, y: nsY, width: size.width, height: size.height)
    }

    private func handleReplace() {
        guard case .result(_, let rewritten, _, _, _) = lastObservedState else { return }
        // Re-validate focus and replace via AXBridge. Snapshot kept in `_currentFocusedElement`.
        if let element = _currentFocusedElement {
            let result = ax.replaceSelection(rewritten, in: element)
            switch result {
            case .okAX, .okPaste: popup.hide()
            case .failed(let msg):
                if msg.contains("focus changed") { setState(.error(.focusLost)) }
                else { setState(.error(.backendUnavailable(message: msg))) }
            }
        } else {
            // No focused element (Electron / Chrome / Terminal path) — clipboard
            // is the best we can do. Write the rewrite and dismiss; user pastes with Cmd+V.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rewritten, forType: .string)
            ClipboardGuard.shared.recordOwletChangeCount(NSPasteboard.general.changeCount)
            popup.hide()
        }
    }

    private func handleCopy() {
        guard case .result(_, let rewritten, _, _, _) = lastObservedState else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rewritten, forType: .string)
        ClipboardGuard.shared.recordOwletChangeCount(NSPasteboard.general.changeCount)
    }

    private func handleCancel() { popup.hide() }
}
