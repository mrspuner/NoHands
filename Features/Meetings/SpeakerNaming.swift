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

        // A read purely to catch a book that will not parse, once, before a single file is
        // touched — its result is discarded rather than threaded into the loop below. Every
        // per-file `mutate` further down reads the book fresh on its own, so a book that stays
        // broken for the whole pass would otherwise have every one of those reads independently
        // rediscover the same fault and report it once per meeting in the archive, instead of
        // once for the whole pass the way this used to read.
        guard (try? await store.book()) != nil else {
            // A book that does not parse is not overwritten and not guessed at — see
            // `VoiceStore.book`. Nothing here can proceed without it, and this pass is the
            // channel by which the owner learns it: the meeting pipeline stays silent about a
            // broken book rather than clobber it.
            report(Outcome(file: "", named: [], failure: "Книга голосов не читается"))
            return
        }

        for file in files() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            await processOne(file: file, text: text)
        }
    }

    /// One file's whole decision — read, refuse or compute, write, record — made inside a single
    /// `VoiceStore.mutate` call, so it can never be undone by a save another writer makes while
    /// this file is being handled, and can never undo a save another writer already made before
    /// it. The book is not threaded from file to file any more: each file reads it fresh, right
    /// here, which is what makes a change that lands between two files of the same pass visible
    /// to the second one instead of overwritten by whatever the first one started from.
    private func processOne(file: URL, text: String) async {
        // Somebody else's note in this Obsidian folder has no row in the book at all, and is
        // skipped without a word — same rule `MeetingSummarizer` applies to the heading. A plain
        // read rather than the `mutate` below: this is a cheap filter for whether the file is
        // worth opening a transaction over at all, not the decision itself. The decision reads
        // the book again, fresh, inside `mutate`, so a rename landing on this exact file between
        // this check and that read is still seen, not raced against.
        guard let peek = try? await store.book(),
            let known = peek.labels(for: file.lastPathComponent), !known.labels.isEmpty
        else { return }

        // Unlike a stray note, a file the book *does* know always had a header written by this
        // application. A header here that no longer parses is the owner having broken it while
        // editing, and he gets no other channel to hear that from. Text-only, so it does not need
        // the book and does not need to be inside the transaction below.
        guard let listed = ParticipantsLine.parse(text) else {
            report(
                Outcome(
                    file: file.lastPathComponent, named: [],
                    failure: "Строка participants не читается — шапка правлена мимо формата"
                )
            )
            return
        }

        // Cheap and advisory, same as the peek above: if the header, as it reads right now,
        // cannot possibly ask `rename` for anything, opening a transaction just to have it reach
        // that very same "nothing to do" conclusion would still cost this file a `VoiceStore`
        // read and `mutate`'s own unconditional save of a byte-identical book — on every pass,
        // for every meeting whose name is already settled, which is most of the archive most of
        // the time, since passes run at launch and after every meeting. `mightRename` mirrors the
        // exact condition `rename` uses to decide there is nothing to apply — see the comment
        // there — so `false` here is not a guess, it is a claim that `rename`, run this instant
        // against this same book state, would return `nil` too, without a report. A header whose
        // length does not even match is deliberately left to the transaction below rather than
        // characterised here — a length mismatch is a refusal the owner needs told about, and
        // reporting it from a copy of the book that might be a moment stale is not worth saving
        // one read over.
        guard Self.mightRename(known: known, listed: listed) else { return }

        do {
            let outcome = try await store.mutate { book in
                Self.rename(in: &book, file: file, text: text, listed: listed)
            }
            if let outcome { report(outcome) }
        } catch {
            // Everything that can go wrong with the file itself is caught inside `rename` below
            // and turned into a returned `Outcome`, never a throw — so the only way `mutate`
            // itself throws is its own machinery: the read at its start failing (the book broke
            // between the pass-level check above and this file — nothing but `save` ever writes
            // to it, and `save` never writes anything invalid, so this is not reachable from
            // inside this application) or, the reachable case, its save at the end failing after
            // `rename` already rewrote the file on disk. The label changed on disk, but the book
            // does not know it — the same divergence Finding A guarded against, arriving through
            // a live failure instead of a lost one.
            report(
                Outcome(
                    file: file.lastPathComponent, named: [],
                    failure: "Метка переименована в файле, но книга голосов не сохранена: "
                        + error.localizedDescription
                )
            )
        }
    }

    /// Whether `rename`, given a book shaped like `known` and this exact header, could possibly
    /// do or say anything at all. `false` means every position's typed name already equals what
    /// the book remembers for it — precisely the condition under which `rename`'s own `renamed`
    /// collection below comes back empty and it returns `nil` without touching the book or
    /// reporting anything.
    ///
    /// Deliberately narrow: a header whose length does not match `known.labels.count` answers
    /// `true` here without trying to characterise the mismatch — that refusal, and the two
    /// per-position refusals inside `rename` (`invalidName`, the duplicate-label check), are all
    /// only ever reachable at a position where the typed name differs from `renderedName` in the
    /// first place, so a `false` answer here rules them out along with an actual rename. If this
    /// and `rename`'s own `renamed` loop below ever disagree about that condition, this function
    /// would start silently skipping files that still needed work — keep the two in step.
    private static func mightRename(known: MeetingLabels, listed: [String]) -> Bool {
        let voices = listed.first == "Я" ? Array(listed.dropFirst()) : listed
        guard voices.count == known.labels.count else { return true }
        let sortedKnown = known.labels.sorted { $0.position < $1.position }
        for (index, label) in sortedKnown.enumerated() {
            let typed = voices[index]
            if typed != label.renderedName, !typed.isEmpty { return true }
        }
        return false
    }

    /// The whole per-file decision, run once inside the caller's `VoiceStore.mutate`.
    ///
    /// - Returns: `nil` when there is nothing to report — the header already matches what the
    ///   book remembers, or the row vanished between the caller's cheap peek and this read (the
    ///   file became a stranger's note in the meantime, or another pass already resolved it). An
    ///   `Outcome` otherwise, success or refusal alike.
    ///
    /// Every refusal returns before `book` is touched at all, and the file write below is the
    /// last thing that can fail — both leave `book` exactly as `mutate` read it, so its own save
    /// afterwards persists that unchanged copy rather than anything this call computed.
    private static func rename(
        in book: inout VoiceBook, file: URL, text: String, listed: [String]
    ) -> Outcome? {
        guard let known = book.labels(for: file.lastPathComponent), !known.labels.isEmpty else {
            return nil
        }

        // The header lists the owner first when he spoke; the labels never include him.
        let voices = listed.first == "Я" ? Array(listed.dropFirst()) : listed
        guard voices.count == known.labels.count else {
            return Outcome(
                file: file.lastPathComponent, named: [],
                failure: "В шапке \(voices.count) участников, а размечено \(known.labels.count) —"
                    + " строка правится, а не переписывается целиком"
            )
        }

        let sortedKnown = known.labels.sorted { $0.position < $1.position }

        if let reason = invalidName(among: sortedKnown, typed: voices) {
            return Outcome(file: file.lastPathComponent, named: [], failure: reason)
        }

        // An "unsupported split": two positions the book already treats as one voice — they
        // share a rendered label, which only happens once they have already been merged — asked
        // to become two different names again. There is no way to tell, at the level of
        // fingerprints, which print belonged to which of the two any more, so this is refused
        // rather than guessed at.
        var typedByRenderedName: [String: Set<String>] = [:]
        for (index, label) in sortedKnown.enumerated() {
            typedByRenderedName[label.renderedName, default: []].insert(voices[index])
        }
        guard !typedByRenderedName.values.contains(where: { $0.count > 1 }) else {
            return Outcome(
                file: file.lastPathComponent, named: [],
                failure: "Две позиции с одной и той же меткой получили разные имена —"
                    + " разделить уже слитый голос это приложение не умеет"
            )
        }

        // The whole set of renames this file needs, computed once — see `ParticipantsLine
        // .rename` for why applying them one at a time over a running copy would alias. The
        // condition below — `typed != label.renderedName && !typed.isEmpty` — is exactly what
        // `mightRename` above tests before this transaction is even opened; keep the two in step.
        var mapping: [String: String] = [:]
        var renamed: [MeetingLabels.Label] = []
        for (index, label) in sortedKnown.enumerated() {
            let typed = voices[index]
            guard typed != label.renderedName, !typed.isEmpty else { continue }
            mapping[label.renderedName] = typed
            renamed.append(label)
        }
        guard !renamed.isEmpty else { return nil }

        // Applied to a scratch copy of the book, committed into `book` only once this file's
        // write below has actually succeeded. A book taught a name ahead of a write that then
        // fails would claim a name for a file whose transcript still shows the old label — and
        // since the row's `renderedName` would already match, the next pass would see no change
        // and never touch that file again to fix it.
        var fileBook = book

        // Vacate every renamed voice to a name unique to this pass before assigning any real
        // target. Assigning targets straight away is what corrupts a plain swap: renaming the
        // first voice to the name the second voice currently holds merges the two — mixing one
        // person's fingerprints into another's — before the second voice's own rename is even
        // considered. Once every renamed voice has been moved off its old name, a name still
        // held by somebody when the second pass below runs is a genuine collision — either a
        // deliberate convergence within this same batch (two positions renamed to the same name,
        // which is how a split voice is repaired) or a match with a voice outside this file
        // entirely — and only then does a merge belong.
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

        // The rows are rewritten with what the file now shows, so the next pass sees no change.
        // The vacate-then-assign above may have merged voices, so identities are re-read from
        // `fileBook` rather than reused: an absorbed id no longer names a voice at all.
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
        } catch {
            // `book` (the real, inout one) was never touched above — only the scratch `fileBook`
            // was — so returning here without assigning it leaves `book` exactly as `mutate`
            // read it, and its own save persists that unchanged copy.
            return Outcome(file: file.lastPathComponent, named: [], failure: error.localizedDescription)
        }
        book = fileBook
        return Outcome(file: file.lastPathComponent, named: named, failure: nil)
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
