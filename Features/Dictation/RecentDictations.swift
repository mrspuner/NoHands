import Foundation

/// The last few dictations, kept in memory until the application quits.
///
/// A dictation can fail to land: the accessibility permission may be missing, or the paste may
/// go somewhere unexpected. Before this existed the text was gone the moment the next copy
/// overwrote the clipboard. Now the last ten are two clicks away.
///
/// Only the newest keeps its recording. The audio exists for a future word-correction window,
/// which needs exactly one; ten recordings of the owner's speech on a 256 GB disk is the
/// failure this guards against.
///
/// Main-actor rather than an actor: everything that touches it — the coordinator and the menu —
/// already runs there, and `NSMenu` rebuilds itself synchronously and cannot await.
@MainActor
public final class RecentDictations {
    /// Ten covers a working session and still reads from a menu at a glance.
    public static let capacity = 10

    public struct Entry: Equatable, Identifiable {
        public let id: UUID
        public let raw: String
        public let cleaned: String?
        /// Set only on the newest entry; see the type's documentation.
        ///
        /// `fileprivate(set)` rather than the `private(set)` the spec sketches: the enclosing
        /// class has to clear this when a newer dictation takes over the file, and it lives
        /// outside the struct's own scope.
        public fileprivate(set) var audio: URL?

        /// What was actually inserted: the cleaned text, or the raw text when cleanup failed.
        public var inserted: String { cleaned ?? raw }
        public var wasCleaned: Bool { cleaned != nil }

        public init(id: UUID = UUID(), raw: String, cleaned: String?, audio: URL?) {
            self.id = id
            self.raw = raw
            self.cleaned = cleaned
            self.audio = audio
        }
    }

    private var stored: [Entry] = []

    public init() {}

    /// Newest first.
    public func entries() -> [Entry] {
        stored
    }

    public func remember(raw: String, cleaned: String?, audio: URL?) {
        // Order matters. The previous newest gives up its file first, then the new entry goes
        // in, then the tail is trimmed. Trimming first could carry an entry out of the ring
        // while it still owned a file, and nothing would ever delete it.
        releaseAudio()
        stored.insert(Entry(raw: raw, cleaned: cleaned, audio: audio), at: 0)
        if stored.count > Self.capacity {
            stored.removeLast(stored.count - Self.capacity)
        }
    }

    /// Deletes the held recording, if any. Texts are untouched: they are the safety net and
    /// outlive the coordinator, while the audio belongs to it.
    public func discardAudio() {
        releaseAudio()
    }

    private func releaseAudio() {
        guard let index = stored.firstIndex(where: { $0.audio != nil }) else { return }
        if let url = stored[index].audio {
            try? FileManager.default.removeItem(at: url)
        }
        stored[index].audio = nil
    }
}
