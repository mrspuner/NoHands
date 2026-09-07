import Foundation

/// The envelope recognised speech travels in on its way to any model.
///
/// Introduced for dictation on 2026-09-05, after «объясни, как работает фотосинтез» came back as
/// a lecture about chloroplasts instead of as a cleaned-up sentence: an unmarked user message is
/// read as a request, and a request that can be carried out gets carried out. Meetings need it
/// more, not less — people say things out loud on a call that read as tasks.
///
/// Russian rather than `<transcript>`: both stopped the substitutions, but the English one obeyed
/// a deliberate "ignore previous instructions" once in five runs where this one obeyed none.
///
/// Lives in code rather than in the prompt: the prompt is a key in the owner's `config.json`, and
/// `loadOrCreate` only fills in missing keys, so a fix written there never reaches an
/// installation that already has one.
enum TranscriptEnvelope {
    static let openingMarker = "<расшифровка>"
    static let closingMarker = "</расшифровка>"

    static func wrapped(_ text: String) -> String {
        "\(openingMarker)\n\(text)\n\(closingMarker)"
    }
}
