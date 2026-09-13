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

    /// - Parameter labels: `nil` when diarization found no real voices this run — the same
    ///   distinction `MeetingMarkdown.render` makes between "no diarization info" and "diarized,
    ///   found nobody". The caller must pass `nil` here rather than a `SpeakerLabels` built from
    ///   the merged transcript: `VoiceAssignment.assign` falls back to a placeholder `"v1"` voice
    ///   for every word when the diarizer's own voice list is empty, so `SpeakerLabels.make` on
    ///   that transcript reports a non-empty `order` even though nothing was actually diarized —
    ///   and treating that as knowledge is exactly the false claim this parameter exists to
    ///   refuse. When `nil`, the `participants:` line is left exactly as found: never inserted,
    ///   and — just as importantly — never overwritten, because "diarization found nobody this
    ///   time" must not downgrade a `participants:` line an earlier, good run already earned. The
    ///   transcript body itself is replaced either way.
    public static func replace(
        in file: String,
        transcript: [Utterance],
        labels: SpeakerLabels?,
        named name: String
    ) throws -> String {
        var lines = file.components(separatedBy: "\n")
        guard let heading = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == TranscriptIndex.heading
        }) else { throw Failure.noTranscriptSection(name) }

        var head = Array(lines[...heading])
        if let labels, !labels.order.isEmpty {
            // A `speakers:` line only ever means diarization failed — see
            // `MeetingMarkdown.render`. Once diarization has succeeded, that claim is stale, and
            // leaving it standing beside the new `participants:` would assert both "we know who
            // this is" and "не размечено" at once, permanently — the file has no reader left who
            // can tell which half is true.
            head.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("speakers:") }

            let participants = ParticipantsLine.key + " ["
                + labels.participants.map(Frontmatter.listValue).joined(separator: ", ") + "]"
            if let index = head.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix(ParticipantsLine.key)
            }) {
                head[index] = participants
            } else if head.first?.trimmingCharacters(in: .whitespaces) == "---",
                let close = head.dropFirst().firstIndex(where: {
                    $0.trimmingCharacters(in: .whitespaces) == "---"
                }) {
                // The same position `MeetingMarkdown.render` puts this line in — after
                // everything else the header carries and before `microphone:` — so a
                // re-diarized file is not visibly different from one written in a single pass.
                let insertAt = head[..<close].firstIndex {
                    $0.trimmingCharacters(in: .whitespaces).hasPrefix("microphone:")
                } ?? close
                head.insert(participants, at: insertAt)
            }
        }

        var out = head
        out.append("")
        for utterance in transcript {
            out.append(
                "[\(MeetingMarkdown.timestamp(utterance.start))] "
                    + "\(label(utterance.speaker, labels)): \(utterance.text)"
            )
        }
        out.append("")
        lines = out
        return lines.joined(separator: "\n")
    }

    /// The same fallback `MeetingMarkdown.render` uses: without labels, a voice reads as the bare
    /// word phase 2б wrote, and the owner still reads as `Я`.
    private static func label(_ speaker: Utterance.Speaker, _ labels: SpeakerLabels?) -> String {
        labels?.label(for: speaker) ?? (speaker == .me ? "Я" : "Собеседник")
    }
}
