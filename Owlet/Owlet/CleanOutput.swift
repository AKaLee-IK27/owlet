import Foundation

enum CleanOutput {

    private static let thinkBlock = try! NSRegularExpression(
        pattern: "<think>.*?</think>",
        options: [.dotMatchesLineSeparators, .caseInsensitive]
    )

    /// Strip <think>…</think> blocks (safety net even with `think: false`)
    /// and remove wrapping quotes if and only if they appear exactly twice.
    static func clean(_ raw: String) -> String {
        let stripped = stripThinkBlocks(raw)
        return stripWrappingQuotes(stripped)
    }

    private static func stripThinkBlocks(_ raw: String) -> String {
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        return thinkBlock.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
    }

    private static func stripWrappingQuotes(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              let first = trimmed.first,
              first == trimmed.last,
              first == "\"" || first == "'",
              trimmed.filter({ $0 == first }).count == 2
        else { return trimmed }
        let inner = trimmed.dropFirst().dropLast()
        return String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
