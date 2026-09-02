import Foundation

/// The most recent dictation, kept in memory until the next one replaces it.
///
/// A word only reveals itself as misheard when the text is already in the field, and by then
/// there is nothing left to look at: cleanup cannot repair a name it has never seen, so the
/// difference between raw and cleaned text does not point at those cases either. Keeping the
/// last recording and both versions of its text is what makes a later correction window
/// possible at all — the window itself is deliberately not part of phase 1.
///
/// One recording, never two: a growing pile of audio on a 256 GB disk is the failure mode this
/// is guarding against.
public actor LastDictation {
    public struct Entry: Equatable, Sendable {
        public let audio: URL
        public let raw: String
        public let cleaned: String?

        public init(audio: URL, raw: String, cleaned: String?) {
            self.audio = audio
            self.raw = raw
            self.cleaned = cleaned
        }
    }

    private var entry: Entry?

    public init() {}

    public func remember(_ entry: Entry) {
        if let previous = self.entry, previous.audio != entry.audio {
            try? FileManager.default.removeItem(at: previous.audio)
        }
        self.entry = entry
    }

    public func current() -> Entry? {
        entry
    }
}
