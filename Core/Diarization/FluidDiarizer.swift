import FluidAudio
import Foundation

/// FluidAudio's offline pipeline: pyannote segmentation, WeSpeaker embeddings, PLDA and VBx,
/// all CoreML on the Neural Engine.
///
/// Measured on 2026-09-10 over the real archive: 120–137× realtime, 825 MB peak on a 68-minute
/// meeting, models 21 MB. Compressed tracks are read as readily as raw ones — the library opens
/// the file through `AVAudioFile`, exactly as Parakeet does — and an AAC 32 kbit/s copy of a
/// voice matches its own raw WAV at cosine 0.970.
///
/// The clustering threshold is left at the library default on purpose. It is not monotonic:
/// on one meeting 0.6 gives four speakers, 0.65 gives seven, 0.8 gives six. Splitting is
/// undone afterwards, by `VoiceClustering`, with a threshold that can actually be tuned.
public actor FluidDiarizer: Diarizing {
    private nonisolated(unsafe) let manager: OfflineDiarizerManager

    private init(manager: OfflineDiarizerManager) {
        self.manager = manager
    }

    /// Downloads the models on first call (21 MB) and compiles them.
    public static func load() async throws -> FluidDiarizer {
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        do {
            try await manager.prepareModels()
        } catch {
            throw DiarizationError.modelUnavailable(error.localizedDescription)
        }
        return FluidDiarizer(manager: manager)
    }

    public func segments(of audio: URL) async throws -> [VoiceSegment] {
        do {
            let result = try await manager.process(audio)
            return VoiceSegment.from(result.segments)
        } catch {
            throw DiarizationError.modelUnavailable(error.localizedDescription)
        }
    }
}
