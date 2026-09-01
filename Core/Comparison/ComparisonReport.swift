import Foundation

/// Formats an alignment for a human to read.
///
/// The summary line exists for tracking regressions between runs. The list below it is the
/// part that matters: the reference is a competing service, not ground truth, so every
/// divergence is a question of which side got it right.
public enum ComparisonReport {
    public static func render(_ result: WordDiff.Result, contextWords: Int = 4) -> String {
        let percent = String(format: "%.1f%%", result.errorRate * 100)
        var lines = [
            "Расхождений: \(percent) от \(result.referenceWordCount) слов эталона",
            "замен: \(result.substitutions), пропусков: \(result.deletions), лишних: \(result.insertions)",
            "",
        ]

        var divergences: [String] = []
        for (index, operation) in result.operations.enumerated() {
            let description: String
            switch operation {
            case .match:
                continue
            case .substitution(let reference, let candidate):
                description = "эталон «\(reference)» → у нас «\(candidate)»"
            case .deletion(let word):
                description = "пропущено «\(word)»"
            case .insertion(let word):
                description = "лишнее «\(word)»"
            }
            divergences.append("  \(context(around: index, in: result.operations, words: contextWords))\n    \(description)")
        }

        if divergences.isEmpty {
            lines.append("расхождений нет")
        } else {
            lines.append(contentsOf: divergences)
        }

        return lines.joined(separator: "\n")
    }

    private static func context(around index: Int, in operations: [WordDiff.Operation], words: Int) -> String {
        let lower = Swift.max(0, index - words)
        let upper = Swift.min(operations.count - 1, index + words)
        let fragment = operations[lower...upper].map { operation -> String in
            switch operation {
            case .match(let word): return word
            case .substitution(let reference, _): return "[\(reference)]"
            case .deletion(let word): return "[-\(word)]"
            case .insertion(let word): return "[+\(word)]"
            }
        }
        return "…" + fragment.joined(separator: " ") + "…"
    }
}
