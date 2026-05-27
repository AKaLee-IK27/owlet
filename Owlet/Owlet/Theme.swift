import SwiftUI

/// Centralized design tokens for Owlet's popup UI.
/// Inspired by Grammarly's card aesthetic: rounded card, soft palette,
/// light/dark adaptive, gentle motion.
enum Theme {

    // MARK: Card geometry
    enum Card {
        static let width: CGFloat = 480
        static let minHeight: CGFloat = 240
        static let maxHeight: CGFloat = 480
        static let cornerRadius: CGFloat = 14
        static let padding: CGFloat = 20
    }

    // MARK: Animations
    enum Motion {
        static let entry: Animation = .easeOut(duration: 0.18)
        static let exit: Animation = .easeIn(duration: 0.12)
        static let stateTransition: Animation = .easeInOut(duration: 0.20)
        static let entryOffset: CGFloat = 8
        static let shimmerPeriod: TimeInterval = 1.5
    }

    // MARK: Typography
    enum Fonts {
        static let body: Font = .system(size: 13, weight: .regular)
        static let sectionHeader: Font = .system(size: 11, weight: .semibold)
        static let wordmark: Font = .system(size: 11, weight: .medium)
    }

    // MARK: Colors (system-derived; adapt to light/dark and accent automatically)
    enum Colors {
        static let textPrimary: Color = .primary
        static let textSecondary: Color = .secondary
        static let textTertiary: Color = Color(nsColor: .tertiaryLabelColor)
        static let actionPrimary: Color = .accentColor

        // Diff highlights (additions in green tint, removals in red tint + strikethrough)
        static let addedBackground: Color = Color.green.opacity(0.18)
        static let addedForeground: Color = Color.green
        static let removedBackground: Color = Color.red.opacity(0.14)
        static let removedForeground: Color = Color.red
    }
}
