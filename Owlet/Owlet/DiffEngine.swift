import Foundation

struct DiffSegment: Equatable, Hashable {
    enum Kind: Equatable, Hashable { case unchanged, added, removed }
    let text: String
    let kind: Kind
}

struct DiffResult: Equatable {
    let segments: [DiffSegment]
    let removedRatio: Double

    /// Threshold above which the inline diff is too noisy to be useful and
    /// the popup should fall back to rendering plain rewritten text.
    static let collapseThreshold: Double = 0.70

    static func shouldCollapse(removedRatio: Double) -> Bool {
        removedRatio > collapseThreshold
    }
}

enum DiffEngine {

    /// Word-tokenized diff between original and rewritten text.
    /// Uses `CollectionDifference` (Apple's Myers-style implementation).
    static func diff(_ original: String, _ rewritten: String) -> DiffResult {
        let origWords = tokenize(original)
        let newWords = tokenize(rewritten)

        let difference = newWords.difference(from: origWords)

        // Build an inserts and removes index map for efficient merging.
        var inserts = [Int: String]()
        var removes = Set<Int>()
        for change in difference {
            switch change {
            case .insert(let offset, let element, _): inserts[offset] = element
            case .remove(let offset, _, _):           removes.insert(offset)
            }
        }

        var segments: [DiffSegment] = []
        var originalIndex = 0
        var newIndex = 0

        while originalIndex < origWords.count || newIndex < newWords.count {
            // First: drain removes at current originalIndex.
            while originalIndex < origWords.count, removes.contains(originalIndex) {
                segments.append(DiffSegment(text: origWords[originalIndex], kind: .removed))
                originalIndex += 1
            }
            // Then: drain inserts at current newIndex.
            while let inserted = inserts[newIndex] {
                segments.append(DiffSegment(text: inserted, kind: .added))
                inserts.removeValue(forKey: newIndex)
                newIndex += 1
            }
            // Then: an unchanged match.
            if originalIndex < origWords.count, newIndex < newWords.count,
               origWords[originalIndex] == newWords[newIndex] {
                segments.append(DiffSegment(text: origWords[originalIndex], kind: .unchanged))
                originalIndex += 1
                newIndex += 1
            } else if originalIndex >= origWords.count, newIndex >= newWords.count {
                break
            } else if originalIndex < origWords.count {
                // Defensive: shouldn't occur if difference is well-formed.
                segments.append(DiffSegment(text: origWords[originalIndex], kind: .removed))
                originalIndex += 1
            } else {
                // Defensive: shouldn't occur if difference is well-formed.
                segments.append(DiffSegment(text: newWords[newIndex], kind: .added))
                newIndex += 1
            }
        }

        let removedCount = segments.lazy.filter { $0.kind == .removed }.count
        let ratio = origWords.isEmpty ? 0.0 : Double(removedCount) / Double(origWords.count)

        return DiffResult(segments: segments, removedRatio: ratio)
    }

    /// Whitespace-split tokenizer. Punctuation stays attached to words —
    /// good enough for prompt-level diffs; revisit if tokenization granularity
    /// becomes a UX problem.
    private static func tokenize(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}
