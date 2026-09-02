import Foundation

/// Turns an audio file into plain text.
///
/// Implementations differ in where the work happens: `ScribeTranscriber` sends the file
/// to ElevenLabs, `ParakeetTranscriber` runs a local model. Everything that differs between
/// them — language, vocabulary, model choice — is configured on the concrete type, not here.
public protocol Transcriber: Sendable {
    func transcribe(audio url: URL) async throws -> String
}
