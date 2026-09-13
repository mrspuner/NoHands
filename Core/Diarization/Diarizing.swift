import FluidAudio
import Foundation

/// What the pipeline needs from a diarizer, and the whole of it.
///
/// Behind it stands CoreML, which no test process can raise; in front of it stand the parts of
/// phase 2г that decide who is who, and those are pure. The boundary is here for that reason
/// and not for a second implementation — there is none planned.
public protocol Diarizing: Sendable {
    func segments(of audio: URL) async throws -> [VoiceSegment]
}

public enum DiarizationError: Error, LocalizedError, Equatable {
    case modelUnavailable(String)
    case noSpeech

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason):
            return "Diarization model unavailable: \(reason)"
        case .noSpeech:
            return "No speech detected on the interlocutors' track"
        }
    }

    static func from(_ error: any Error) -> DiarizationError {
        // Pass through already-mapped errors unchanged.
        if let mapped = error as? DiarizationError {
            return mapped
        }

        // Extract the one distinguishable failure case from FluidAudio.
        if let fluidError = error as? OfflineDiarizationError {
            if case .noSpeechDetected = fluidError {
                return .noSpeech
            }
        }

        // Everything else, including other OfflineDiarizationError cases and unrelated errors.
        return .modelUnavailable(error.localizedDescription)
    }
}
