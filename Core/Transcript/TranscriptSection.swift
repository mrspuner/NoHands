import Foundation

/// Replaces the transcript of an existing meeting file, and its `participants:` line, leaving
/// everything above the transcript heading alone.
///
/// The counterpart of `SummaryInsertion`, which writes above the heading and leaves the
/// transcript alone. Between them the file has two owners and no overlap: re-diarizing a meeting
/// must not cost it its summary, and summarising must not cost it its speaker labels.
public enum TranscriptSection {
    public enum Failure: LocalizedError, Equatable {
        case noTranscriptSection(String)

        public var errorDescription: String? {
            switch self {
            case .noTranscriptSection(let name):
                return "No \(TranscriptIndex.heading) section in \(name) — nothing this pipeline wrote"
            }
        }
    }

    public static func replace(
        in file: String,
        transcript: [Utterance],
        labels: SpeakerLabels,
        named name: String
    ) throws -> String {
        var lines = file.components(separatedBy: "\n")
        guard let heading = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == TranscriptIndex.heading
        }) else { throw Failure.noTranscriptSection(name) }

        var head = Array(lines[...heading])
        let participants = ParticipantsLine.key + " ["
            + labels.participants.map(Frontmatter.listValue).joined(separator: ", ") + "]"
        if let index = head.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(ParticipantsLine.key)
        }) {
            head[index] = participants
        } else if head.first?.trimmingCharacters(in: .whitespaces) == "---",
            let close = head.dropFirst().firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == "---"
            }), !labels.order.isEmpty {
            head.insert(participants, at: close)
        }

        var out = head
        out.append("")
        for utterance in transcript {
            out.append(
                "[\(MeetingMarkdown.timestamp(utterance.start))] "
                    + "\(labels.label(for: utterance.speaker)): \(utterance.text)"
            )
        }
        out.append("")
        lines = out
        return lines.joined(separator: "\n")
    }
}
