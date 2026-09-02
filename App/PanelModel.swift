import AppKit
import Dictation
import SwiftUI

/// What the panel is drawing right now.
@MainActor
final class PanelModel: ObservableObject {
    @Published var state: PanelState?
    /// A short history rather than one number: a single bar jumping around reads as noise,
    /// while a row of recent levels reads as a voice.
    @Published var levels: [Float] = Array(repeating: 0, count: 32)

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: 32)
    }
}
