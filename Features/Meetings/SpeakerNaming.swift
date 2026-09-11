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
    /// Refuses to run over itself: two overlapping passes would read one file before the other
    /// had written it and undo each other's edits. Unlike `MeetingSummarizer.scanArchive`, a
    /// request that arrives mid-pass is simply dropped here rather than remembered for one more
    /// pass afterwards — that guarantee now lives one level up, in `ArchivePasses`, which
    /// serializes this pass against `MeetingSummarizer`'s and keeps the one request
    /// `MeetingSummarizer` itself already keeps. This guard stays anyway, belt and braces: nothing
    /// stops a future caller from holding a `SpeakerNaming` of its own.
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
            // Unlike a stray note, a file the book *does* know always had a header written by
            // this application. A header here that no longer parses is the owner having broken
            // it while editing, and he gets no other channel to hear that from.
            guard let listed = ParticipantsLine.parse(text) else {
                report(
                    Outcome(
                        file: file.lastPathComponent, named: [],
                        failure: "Строка participants не читается — шапка правлена мимо формата"
                    )
                )
                continue
            }

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

            if let reason = Self.invalidName(among: sortedKnown, typed: voices) {
                report(Outcome(file: file.lastPathComponent, named: [], failure: reason))
                continue
            }

            // An "unsupported split": two positions the book already treats as one voice — they
            // share a rendered label, which only happens once they have already been merged —
            // asked to become two different names again. There is no way to tell, at the level of
            // fingerprints, which print belonged to which of the two any more, so this is refused
            // rather than guessed at.
            var typedByRenderedName: [String: Set<String>] = [:]
            for (index, label) in sortedKnown.enumerated() {
                typedByRenderedName[label.renderedName, default: []].insert(voices[index])
            }
            guard !typedByRenderedName.values.contains(where: { $0.count > 1 }) else {
                report(
                    Outcome(
                        file: file.lastPathComponent, named: [],
                        failure: "Две позиции с одной и той же меткой получили разные имена —"
                            + " разделить уже слитый голос это приложение не умеет"
                    )
                )
                continue
            }

            // The whole set of renames this file needs, computed once — see `ParticipantsLine
            // .rename` for why applying them one at a time over a running copy would alias.
            var mapping: [String: String] = [:]
            var renamed: [MeetingLabels.Label] = []
            for (index, label) in sortedKnown.enumerated() {
                let typed = voices[index]
                guard typed != label.renderedName, !typed.isEmpty else { continue }
                mapping[label.renderedName] = typed
                renamed.append(label)
            }
            guard !renamed.isEmpty else { continue }

            // Applied to a scratch copy of the book, committed into `book` only once this file's
            // write below has actually succeeded. A book taught a name ahead of a write that then
            // fails would claim a name for a file whose transcript still shows the old label —
            // and since the row's `renderedName` would already match, the next pass would see no
            // change and never touch that file again to fix it.
            var fileBook = book

            // Vacate every renamed voice to a name unique to this pass before assigning any real
            // target. Assigning targets straight away is what corrupts a plain swap: renaming the
            // first voice to the name the second voice currently holds merges the two — mixing
            // one person's fingerprints into another's — before the second voice's own rename is
            // even considered. Once every renamed voice has been moved off its old name, a name
            // still held by somebody when the second pass below runs is a genuine collision —
            // either a deliberate convergence within this same batch (two positions renamed to
            // the same name, which is how a split voice is repaired) or a match with a voice
            // outside this file entirely — and only then does a merge belong.
            for label in renamed {
                guard let voiceId = label.voiceId else { continue }
                fileBook.rename(voiceId, to: "speaker-naming-scratch-\(UUID().uuidString)")
            }
            for label in renamed {
                guard let voiceId = label.voiceId, let target = mapping[label.renderedName] else { continue }
                fileBook.rename(voiceId, to: target)
            }

            let updated = ParticipantsLine.rename(in: text, mapping: mapping)
            let named = renamed.map { mapping[$0.renderedName] ?? $0.renderedName }

            // The rows are rewritten with what the file now shows, so the next pass sees no
            // change. The vacate-then-assign above may have merged voices, so identities are
            // re-read from `fileBook` rather than reused: an absorbed id no longer names a voice
            // at all.
            let rows = sortedKnown.map { label -> MeetingLabels.Label in
                let newName = mapping[label.renderedName] ?? label.renderedName
                let voiceId = label.voiceId.map { id in
                    fileBook.voices.contains { $0.id == id }
                        ? id
                        : (fileBook.voices.first { $0.name == newName }?.id ?? id)
                }
                return MeetingLabels.Label(position: label.position, voiceId: voiceId, renderedName: newName)
            }
            fileBook.record(MeetingLabels(file: file.lastPathComponent, labels: rows))

            do {
                try Data(updated.utf8).write(to: file, options: .atomic)
                book = fileBook
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

    /// A typed name that would break the very thing it is meant to fix — checked against every
    /// position before anything is touched, so the whole file is refused rather than partly
    /// rewritten.
    private static func invalidName(among labels: [MeetingLabels.Label], typed: [String]) -> String? {
        for (index, label) in labels.enumerated() {
            let name = typed[index]
            guard name != label.renderedName, !name.isEmpty else { continue }
            if name.contains(":") {
                return "Имя «\(name)» с двоеточием — метка с ним не разберётся при следующем проходе"
            }
            if isPlaceholder(name) {
                return "Имя «\(name)» похоже на автоматическую метку, а не на настоящее имя"
            }
        }
        return nil
    }

    /// `Собеседник` or `Собеседник <number>` — exactly what this application itself writes for a
    /// voice nobody has named yet, per `SpeakerLabels.label(for:)`. Typing one in as if it were a
    /// real name would store it as one, and it would then compete with real names in later
    /// meetings.
    private static func isPlaceholder(_ name: String) -> Bool {
        guard name == "Собеседник" || name.hasPrefix("Собеседник ") else { return false }
        if name == "Собеседник" { return true }
        return Int(name.dropFirst("Собеседник ".count)) != nil
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
