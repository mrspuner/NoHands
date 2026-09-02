import AppKit
import Foundation

/// The one channel that works while the owner is looking at the text field rather than at the
/// menu bar. System sounds by name — no files in the bundle.
@MainActor
public struct SoundPlayer {
    private let sounds: DictationConfig.Sounds

    public init(sounds: DictationConfig.Sounds) {
        self.sounds = sounds
    }

    public func play(_ sound: DictationMachine.Sound) {
        guard sounds.enabled else { return }
        let name: String
        switch sound {
        case .start: name = sounds.start
        case .done: name = sounds.done
        case .error: name = sounds.error
        }
        NSSound(named: name)?.play()
    }
}
