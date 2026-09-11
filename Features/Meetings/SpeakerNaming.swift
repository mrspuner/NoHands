import Core
import Foundation

/// Carries a name the owner typed into a file's header back into the book, and down into that
/// file's own labels.
///
/// A pass over the archive rather than a watcher: the same shape `MeetingSummarizer` uses, for
/// the same reason — the state is the file itself, an edit made while the application was shut
/// down is picked up for free, and nothing has to be remembered between launches.
public actor SpeakerNaming {
    public struct Outcome: Equatable, Sendable {
        public var file: String
        public var named: [String]
        public var failure: String?

        public init(file: String, named: [String], failure: String?) {
            self.file = file
            self.named = named
            self.failure = failure
        }
    }

    private let archive: URL
    private let store: VoiceStore
    private let report: @Sendable (Outcome) -> Void
    /// See `scanArchive` for why one pass at a time is a requirement rather than a tidiness.
    private var scanning = false

    public init(
        archive: URL = MeetingFolder.archiveURL,
        store: VoiceStore = VoiceStore(),
        report: @escaping @Sendable (Outcome) -> Void
    ) {
        self.archive = archive
        self.store = store
        self.report = report
    }

    /// One pass at a time, exactly like `MeetingSummarizer.scanArchive`: two overlapping passes
    /// would read one file before the other had written it and undo each other's edits.
    public func scanArchive() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }

        guard var book = try? await store.book() else {
            // A book that does not parse is not overwritten and not guessed at — see
            // `VoiceStore.book`. Nothing here can proceed without it, and this pass is the
            // channel by which the owner learns it: the meeting pipeline stays silent about a
            // broken book rather than clobber it.
            report(Outcome(file: "", named: [], failure: "Книга голосов не читается"))
            return
        }

        var changed = false
        for file in files() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // Somebody else's note in this Obsidian folder has no row in the book at all, and is
            // skipped without a word — same rule `MeetingSummarizer` applies to the heading.
            guard let known = book.labels(for: file.lastPathComponent), !known.labels.isEmpty else {
                continue
            }
            guard let listed = ParticipantsLine.parse(text) else { continue }

            // The header lists the owner first when he spoke; the labels never include him.
            let voices = listed.first == "Я" ? Array(listed.dropFirst()) : listed
            guard voices.count == known.labels.count else {
                report(
                    Outcome(
                        file: file.lastPathComponent, named: [],
                        failure: "В шапке \(voices.count) участников, а размечено \(known.labels.count) —"
                            + " строка правится, а не переписывается целиком"
                    )
                )
                continue
            }

            let sortedKnown = known.labels.sorted { $0.position < $1.position }
            var updated = text
            var named: [String] = []
            for (index, label) in sortedKnown.enumerated() {
                let typed = voices[index]
                guard typed != label.renderedName, !typed.isEmpty else { continue }
                // A row without a voice behind it — a speaker too brief to fingerprint — still
                // gets its label rewritten in the file and its row updated below, so the pass is
                // idempotent. It simply teaches the book nothing: there is nothing to teach it
                // about.
                if let voiceId = label.voiceId { book.rename(voiceId, to: typed) }
                updated = ParticipantsLine.rename(in: updated, from: label.renderedName, to: typed)
                named.append(typed)
            }
            guard !named.isEmpty else { continue }

            // The rows are rewritten with what the file now shows, so the next pass sees no
            // change. `book.rename` may have merged two voices, so identities are re-read from
            // the book rather than reused: the absorbed id no longer names a voice at all.
            let rows = sortedKnown.enumerated().map { index, label in
                MeetingLabels.Label(
                    position: label.position,
                    voiceId: label.voiceId.map { id in
                        book.voices.contains { $0.id == id }
                            ? id
                            : (book.voices.first { $0.name == voices[index] }?.id ?? id)
                    },
                    renderedName: voices[index]
                )
            }
            book.record(MeetingLabels(file: file.lastPathComponent, labels: rows))

            do {
                try Data(updated.utf8).write(to: file, options: .atomic)
                changed = true
                report(Outcome(file: file.lastPathComponent, named: named, failure: nil))
            } catch {
                report(
                    Outcome(file: file.lastPathComponent, named: [], failure: error.localizedDescription)
                )
            }
        }

        if changed { try? await store.save(book) }
    }

    private func files() -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: archive, includingPropertiesForKeys: nil
        )
        return (contents ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
