import Foundation
import Testing
@testable import Core

@Test func recordThrowsWhenNoInputDeviceIsAvailable() async throws {
    // This machine currently has no default input device (see AudioInputDeviceTests), which
    // makes the failure path deterministic here rather than something to skip or fake.
    guard AudioInputDevice.current() == nil else {
        return
    }

    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nohands-record-test-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }

    await #expect(throws: RecordingError.noInputDevice) {
        try await MicrophoneRecorder().record(seconds: 1, to: url)
    }
    #expect(!FileManager.default.fileExists(atPath: url.path))
}
