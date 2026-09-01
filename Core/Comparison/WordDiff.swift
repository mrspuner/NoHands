import Foundation

/// Aligns two word sequences and reports where they diverge.
///
/// This is the standard edit-distance alignment used to score speech recognition. The
/// alignment matters as much as the number: the point of phase 0 is to read the divergences
/// and decide which side is right, not to stare at a percentage.
public enum WordDiff {
    public enum Operation: Equatable, Sendable {
        case match(String)
        case substitution(reference: String, candidate: String)
        /// Present in the reference, missing from ours.
        case deletion(String)
        /// Present in ours, missing from the reference.
        case insertion(String)
    }

    public struct Result: Sendable {
        public let operations: [Operation]
        public let referenceWordCount: Int

        public var substitutions: Int {
            operations.count { if case .substitution = $0 { return true } else { return false } }
        }

        public var deletions: Int {
            operations.count { if case .deletion = $0 { return true } else { return false } }
        }

        public var insertions: Int {
            operations.count { if case .insertion = $0 { return true } else { return false } }
        }

        public var errorRate: Double {
            guard referenceWordCount > 0 else { return 0 }
            return Double(substitutions + deletions + insertions) / Double(referenceWordCount)
        }
    }

    public static func compare(reference: [String], candidate: [String]) -> Result {
        let n = reference.count
        let m = candidate.count

        var cost = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = j }

        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    if reference[i - 1] == candidate[j - 1] {
                        cost[i][j] = cost[i - 1][j - 1]
                    } else {
                        cost[i][j] = Swift.min(
                            cost[i - 1][j - 1],  // substitution
                            cost[i - 1][j],      // deletion
                            cost[i][j - 1]       // insertion
                        ) + 1
                    }
                }
            }
        }

        var operations: [Operation] = []
        var i = n
        var j = m

        while i > 0 || j > 0 {
            if i > 0, j > 0, reference[i - 1] == candidate[j - 1], cost[i][j] == cost[i - 1][j - 1] {
                operations.append(.match(reference[i - 1]))
                i -= 1
                j -= 1
            } else if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + 1 {
                operations.append(.substitution(reference: reference[i - 1], candidate: candidate[j - 1]))
                i -= 1
                j -= 1
            } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                operations.append(.deletion(reference[i - 1]))
                i -= 1
            } else {
                operations.append(.insertion(candidate[j - 1]))
                j -= 1
            }
        }

        return Result(operations: operations.reversed(), referenceWordCount: n)
    }
}
