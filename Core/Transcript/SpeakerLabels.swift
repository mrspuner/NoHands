import Foundation

/// How the voices of one meeting are called in its file.
///
/// Derived from the transcript rather than stored with it: the order is the order people first
/// spoke, which is what a reader expects from the header, and a name is whatever the book knows
/// today. The same meeting rendered tomorrow, after the owner has named somebody, produces
/// different labels from the same utterances — that is the point.
public struct SpeakerLabels: Equatable, Sendable {
    /// Voice identities in order of first appearance.
    public var order: [String]
    /// Identity to name, for the voices that have one.
    public var names: [String: String]
    /// Whether the owner said anything at all. A meeting sat through in silence has no `Я` line,
    /// and the header must not claim one.
    public var ownerSpoke: Bool

    public init(order: [String], names: [String: String], ownerSpoke: Bool) {
        self.order = order
        self.names = names
        self.ownerSpoke = ownerSpoke
    }

    public static func make(transcript: [Utterance], names: [String: String]) -> SpeakerLabels {
        var order: [String] = []
        for utterance in transcript {
            guard case .voice(let id) = utterance.speaker, !order.contains(id) else { continue }
            order.append(id)
        }
        return SpeakerLabels(
            order: order,
            names: names,
            ownerSpoke: transcript.contains { $0.speaker == .me }
        )
    }

    public func label(for speaker: Utterance.Speaker) -> String {
        switch speaker {
        case .me:
            return "Я"
        case .voice(let id):
            if let name = names[id], !name.isEmpty { return name }
            guard let position = order.firstIndex(of: id) else { return "Собеседник" }
            // One nameless voice keeps the bare word phase 2б wrote — a meeting with one other
            // person has nothing to number.
            return order.count == 1 ? "Собеседник" : "Собеседник \(position + 1)"
        }
    }

    /// The header list. `Я` first when the owner spoke at all, then the voices in order.
    public var participants: [String] {
        (ownerSpoke ? ["Я"] : []) + order.map { label(for: .voice($0)) }
    }
}
