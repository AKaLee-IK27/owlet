import SwiftUI
import AppKit

/// SwiftUI port of `src/ImprovePromptFloater.jsx` from the v0.4 design handoff.
///
/// 420pt-wide branded popup that hosts the rewriter result (the existing
/// fn+Ctrl+R flow). Replaces the v0.1–v0.3 system-native popup. The design
/// philosophy from the React source: "Quiet-by-default: the rewrite is the
/// hero. Everything else is chrome and chrome whispers — borderless mode
/// chips, inline improvement summary, no 'Original' preview, no model name
/// in the footer."
///
/// **State.** Driven by `PopupState` from RewriterFlow — `.loading` shows
/// skeleton lines + thinking dots; `.result` shows italic-serif text + mode
/// chips + actions; `.empty` shows the unchanged text with a soft note;
/// `.error` shows the error box.
///
/// **Mode chips.** Visible in `.result` only. Currently visual-only — tapping
/// switches the active chip but doesn't re-trigger Ollama because
/// `owlet-rewriter` doesn't yet accept a mode parameter. Wiring modes to
/// distinct SYSTEM_PROMPTs is a follow-up.
///
/// **Improvements line.** Hidden for now (`showImprovements = false`) because
/// the current Ollama call returns plain text, not a structured rewrite-plus-
/// improvements payload. Adding it back requires Ollama to return JSON.
struct ImprovePromptFloater: View {

    let state: PopupState
    let onReplace: () -> Void
    let onCopy: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void

    /// Active chip — visual only until rewrite modes are wired in the backend.
    @State private var activeMode: ImproveMode = .clarify

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 10)

            output.padding(.bottom, 12)

            if case .result(_, _, _, _) = state {
                modeChips.padding(.bottom, 12)
            }

            if shouldShowActions {
                actions
            }
        }
        .padding(OwletDesign.Floater.paddingComfortable)
        .frame(width: OwletDesign.Floater.width, alignment: .topLeading)
        .background(
            // Paper-cream fill over whatever vibrancy the window provides.
            RoundedRectangle(cornerRadius: OwletDesign.Radius.lg, style: .continuous)
                .fill(OwletDesign.floaterFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OwletDesign.Radius.lg, style: .continuous)
                .strokeBorder(OwletDesign.hairline, lineWidth: 1)
        )
    }

    // MARK: Header — owl mark, label, status indicator, close
    private var header: some View {
        HStack(spacing: 8) {
            OwletMark(size: 15)
            Text("Improve prompt")
                .font(OwletDesign.ui(size: 12, weight: .medium))
                .foregroundStyle(OwletDesign.fgMuted)
            Spacer(minLength: 0)
            statusIndicator
            CloseButton(action: onCancel)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if case .loading = state {
            ThinkingDots()
        } else {
            // Static hotkey hint when not thinking — keeps the eye on the
            // rewrite text rather than on chrome.
            Text("⌥ Space")
                .font(OwletDesign.mono(size: 10))
                .foregroundStyle(OwletDesign.fgSubtle)
        }
    }

    // MARK: Output — varies per state
    @ViewBuilder
    private var output: some View {
        switch state {
        case .loading:
            VStack(alignment: .leading, spacing: 9) {
                SkeletonLine(width: 0.94, delay: 0)
                SkeletonLine(width: 0.86, delay: 0.12)
                SkeletonLine(width: 0.72, delay: 0.24)
            }
            .frame(minHeight: 100, alignment: .top)

        case .result(_, let rewritten, _, _):
            italicOutput(rewritten)

        case .empty(let text):
            VStack(alignment: .leading, spacing: 8) {
                italicOutput(text)
                Text("No changes needed.")
                    .font(OwletDesign.ui(size: 11, weight: .medium))
                    .foregroundStyle(OwletDesign.fgSubtle)
            }

        case .error(let kind):
            errorBox(kind: kind)
        }
    }

    private func italicOutput(_ text: String) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(text)
                .font(OwletDesign.displayItalic(size: 17))
                .lineSpacing(17 * 0.5)
                .foregroundStyle(OwletDesign.fg)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
        .frame(maxHeight: 220)
    }

    private func errorBox(kind: ErrorKind) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(OwletDesign.danger)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(errorTitle(for: kind))
                    .font(OwletDesign.ui(size: 13, weight: .medium))
                    .foregroundStyle(OwletDesign.fg)
                Text(errorDetail(for: kind))
                    .font(OwletDesign.ui(size: 12, weight: .regular))
                    .foregroundStyle(OwletDesign.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(OwletDesign.danger.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(OwletDesign.danger.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: Mode chips — visual only for now (no backend wiring yet)
    private var modeChips: some View {
        HStack(spacing: 2) {
            ForEach(ImproveMode.allCases) { m in
                ModeChip(mode: m, active: m == activeMode) {
                    activeMode = m
                    // TODO(v0.5): re-trigger rewrite with this mode's
                    // SYSTEM_PROMPT. owlet-rewriter needs a --mode <name>
                    // flag first, and OllamaClient + Rewriting need a `mode` arg.
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, -6)
    }

    // MARK: Actions — Replace · Try again · spacer · Copy
    private var shouldShowActions: Bool {
        switch state {
        case .loading: return false
        case .result, .empty, .error: return true
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .loading:
            EmptyView()

        case .result(_, _, _, let canReplace):
            HStack(spacing: 4) {
                PrimaryButton(label: "Replace", enabled: canReplace, action: onReplace)
                GhostButton(label: "Try again", action: onRetry)
                Spacer(minLength: 0)
                CopyButton(action: onCopy)
            }

        case .empty:
            HStack(spacing: 4) {
                GhostButton(label: "Dismiss", action: onCancel)
                Spacer(minLength: 0)
                CopyButton(action: onCopy)
            }

        case .error:
            HStack(spacing: 4) {
                PrimaryButton(label: "Try again", enabled: true, action: onRetry)
                GhostButton(label: "Dismiss", action: onCancel)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Error copy
    private func errorTitle(for kind: ErrorKind) -> String {
        switch kind {
        case .selectionEmpty:     return "Select some text first."
        case .passwordField:      return "Owlet won't read from password fields."
        case .selectionUnreadable: return "Couldn't read your selection."
        case .inputTooLong:       return "That selection is too long."
        case .ollamaDown:         return "Couldn't reach Ollama."
        case .timeout:            return "Ollama took too long to respond."
        case .emptyOutput:        return "Ollama returned nothing."
        case .focusLost:          return "Lost focus before Replace landed."
        case .axDenied:           return "Owlet needs Accessibility."
        case .backendUnavailable: return "Something went wrong."
        }
    }

    private func errorDetail(for kind: ErrorKind) -> String {
        switch kind {
        case .selectionEmpty:     return "Highlight a passage in any app, then press fn+Ctrl+R again."
        case .passwordField:      return "Use a different field — your password stays where it is."
        case .selectionUnreadable: return "Some apps (Electron, Chrome) won't let Owlet read directly. Try copying first."
        case .inputTooLong(let c): return "\(c) characters is over the 16,000 limit. Shorten your selection."
        case .ollamaDown:         return "Check that it's running, then try again."
        case .timeout:            return "Try a shorter selection, or check that the model is loaded."
        case .emptyOutput:        return "Try again with slightly different text."
        case .focusLost:          return "Focus the target field again, then re-run."
        case .axDenied:           return "Grant Accessibility in System Settings, then relaunch Owlet."
        case .backendUnavailable(let m): return m
        }
    }
}

// MARK: - Mode enum
// Local to this view since it's purely cosmetic until backend modes ship.
enum ImproveMode: String, CaseIterable, Identifiable {
    case clarify, context, structured, examples, compact
    var id: String { rawValue }

    var label: String {
        switch self {
        case .clarify:    return "Clarify"
        case .context:    return "Add context"
        case .structured: return "Structured"
        case .examples:   return "Examples"
        case .compact:    return "Compact"
        }
    }

    var hint: String {
        switch self {
        case .clarify:    return "Make goals + constraints explicit"
        case .context:    return "Fill in audience, scope, assumptions"
        case .structured: return "Role / task / format / constraints"
        case .examples:   return "Add a few-shot reference"
        case .compact:    return "Specific but short"
        }
    }
}

// MARK: - Small button primitives

private struct CloseButton: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(OwletDesign.fgSubtle)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hover ? OwletDesign.bgSunken : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("Dismiss")
    }
}

private struct ModeChip: View {
    let mode: ImproveMode
    let active: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(mode.label)
                .font(OwletDesign.ui(size: 12, weight: .medium))
                .foregroundStyle(active ? OwletDesign.brand : OwletDesign.fgMuted)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(active
                              ? OwletDesign.brandSoft
                              : (hover ? OwletDesign.bgSunken : .clear))
                )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(mode.hint)
    }
}

private struct PrimaryButton: View {
    let label: String
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false
    @State private var press = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(OwletDesign.ui(size: 13, weight: .medium))
                .foregroundStyle(Color(red: 0xF4/255.0, green: 0xF2/255.0, blue: 0xEA/255.0))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(backgroundColor)
                )
                .scaleEffect(press ? 0.98 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hover = $0 }
        .pressAction { press = $0 }
    }

    private var backgroundColor: Color {
        if !enabled { return OwletDesign.brand }
        if press { return OwletDesign.brandPress }
        if hover { return OwletDesign.Sage.s600 }
        return OwletDesign.brand
    }
}

private struct GhostButton: View {
    let label: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(OwletDesign.ui(size: 13, weight: .medium))
                .foregroundStyle(OwletDesign.fgMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hover ? OwletDesign.bgSunken : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct CopyButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 12))
                .frame(width: 30, height: 30)
                .foregroundStyle(OwletDesign.fgSubtle)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hover ? OwletDesign.bgSunken : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Copy")
    }
}

private struct ThinkingDots: View {
    @State private var phase: Int = 0
    private let dotCount = 3
    private let interval: TimeInterval = 0.4

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<dotCount, id: \.self) { i in
                Circle()
                    .fill(OwletDesign.accent)
                    .frame(width: 4, height: 4)
                    .opacity(phase == i ? 1 : 0.25)
                    .offset(y: phase == i ? -2 : 0)
            }
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                Task { @MainActor in
                    withAnimation(.easeInOut(duration: interval)) {
                        phase = (phase + 1) % dotCount
                    }
                }
            }
        }
        .padding(.trailing, 4)
    }
}

private struct SkeletonLine: View {
    /// Fractional width of the line (0.0–1.0 of available width).
    let width: CGFloat
    let delay: Double
    @State private var shimmerPhase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [OwletDesign.bgSunken, OwletDesign.Paper.p1, OwletDesign.bgSunken],
                        startPoint: UnitPoint(x: shimmerPhase, y: 0),
                        endPoint: UnitPoint(x: shimmerPhase + 1, y: 0)
                    )
                )
                .frame(width: geo.size.width * width, height: 11)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                            shimmerPhase = 2
                        }
                    }
                }
        }
        .frame(height: 11)
    }
}

private extension View {
    func pressAction(_ onPress: @escaping (Bool) -> Void) -> some View {
        self.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in onPress(true) }
                .onEnded { _ in onPress(false) }
        )
    }
}

#Preview("ready") {
    ImprovePromptFloater(
        state: .result(
            original: "write me a blog post about AI",
            rewritten: "Write a 600-word blog post for software engineers about practical uses of local LLMs in daily development workflows. Keep the tone pragmatic, with one concrete example per use case.",
            segments: nil,
            canReplace: true),
        onReplace: {}, onCopy: {}, onCancel: {}, onRetry: {})
    .padding(40)
    .background(OwletDesign.Sage.s800)
}

#Preview("loading") {
    ImprovePromptFloater(
        state: .loading(sourceText: "anything", isLong: false),
        onReplace: {}, onCopy: {}, onCancel: {}, onRetry: {})
    .padding(40)
    .background(OwletDesign.Sage.s800)
}

#Preview("error") {
    ImprovePromptFloater(
        state: .error(.ollamaDown),
        onReplace: {}, onCopy: {}, onCancel: {}, onRetry: {})
    .padding(40)
    .background(OwletDesign.Sage.s800)
}
