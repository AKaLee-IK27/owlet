import Foundation
import AppKit
import ApplicationServices

@MainActor
final class RewriterFlow: CaptureFlow {
    let tag = "rewriter"
    private let ax: AXBridging
    private let rewriter: Rewriting
    private let popup: PopupWindowController

    /// Exposed for tests so they can assert the last state set on the popup.
    private(set) var lastObservedState: PopupState? = nil

    private var _currentFocusedElement: AXUIElement?

    init(ax: AXBridging = AXBridgeAdapter(),
         rewriter: Rewriting = OllamaClient(
            executablePath: NSString(string: "~/repos/owlet/tools/rewriter/.venv/bin/python3")
                .expandingTildeInPath,
            timeoutSeconds: 30
         ),
         popup: PopupWindowController = PopupWindowController()) {
        self.ax = ax
        self.rewriter = rewriter
        self.popup = popup
    }

    private static let inputSoftWarn = 4_000
    private static let inputHardLimit = 16_000
    private static let outputHardLimit = 32_000

    func start() async {
        // 1) Capture
        guard let snap = ax.captureSelection() else {
            setState(.error(.selectionEmpty))
            return
        }
        _currentFocusedElement = snap.focusedElement
        if snap.text.count > Self.inputHardLimit {
            setState(.error(.inputTooLong(charCount: snap.text.count)))
            return
        }

        let isLong = snap.text.count > Self.inputSoftWarn
        setState(.loading(sourceText: snap.text, isLong: isLong))

        // 2) Rewrite
        let rewrittenRaw: String
        do {
            rewrittenRaw = try await rewriter.rewrite(snap.text)
        } catch OllamaClient.Failure.timeout {
            setState(.error(.timeout))
            return
        } catch OllamaClient.Failure.emptyOutput {
            setState(.error(.emptyOutput))
            return
        } catch OllamaClient.Failure.backendError(let msg) {
            // Heuristic: stderr text containing "Connection" maps to ollamaDown.
            if msg.localizedCaseInsensitiveContains("Connection") {
                setState(.error(.ollamaDown))
            } else {
                setState(.error(.backendUnavailable(message: msg)))
            }
            return
        } catch OllamaClient.Failure.launchFailed(let msg) {
            setState(.error(.backendUnavailable(message: msg)))
            return
        } catch {
            setState(.error(.backendUnavailable(message: "\(error)")))
            return
        }

        let rewritten = CleanOutput.clean(rewrittenRaw)
        if rewritten.isEmpty {
            setState(.error(.emptyOutput))
            return
        }
        if rewritten == snap.text.trimmingCharacters(in: .whitespacesAndNewlines) {
            setState(.empty(text: rewritten))
            return
        }

        // 3) Diff
        let diff = DiffEngine.diff(snap.text, rewritten)
        let collapse = DiffResult.shouldCollapse(removedRatio: diff.removedRatio)
        let canReplace = rewritten.count <= Self.outputHardLimit
        setState(.result(original: snap.text,
                          rewritten: rewritten,
                          segments: collapse ? nil : diff.segments,
                          canReplace: canReplace))
    }

    private func setState(_ state: PopupState) {
        lastObservedState = state
        popup.show(
            PopupView(state: state,
                      onReplace: { [weak self] in self?.handleReplace() },
                      onCopy:    { [weak self] in self?.handleCopy() },
                      onCancel:  { [weak self] in self?.handleCancel() },
                      onRetry:   { Task { [weak self] in await self?.start() } }),
            anchorRect: nil // Phase 8 manual smoke: refine anchor from snap.focusedElement
        )
    }

    private func handleReplace() {
        guard case .result(_, let rewritten, _, _) = lastObservedState else { return }
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
            setState(.error(.focusLost))
        }
    }

    private func handleCopy() {
        guard case .result(_, let rewritten, _, _) = lastObservedState else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rewritten, forType: .string)
        popup.hide()
    }

    private func handleCancel() { popup.hide() }
}
