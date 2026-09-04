import Core
import Foundation

/// Turns "who is holding the audio devices" into "which meeting application is doing what".
///
/// Split from `AudioProcessMonitor` so the rule — which processes count, and what our own
/// process must never count as — is testable without any audio hardware.
public enum MeetingWatcher {
    public struct Match: Equatable, Sendable {
        public let app: MeetingMachine.MeetingApp
        public let input: Bool
        public let output: Bool
    }

    public static func match(states: [AudioProcessMonitor.State], config: MeetingsConfig) -> [Match] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return states.compactMap { state in
            // Dictation holds the input too. Recording a meeting because we are recording is
            // the one loop this whole feature must not have.
            guard state.pid != ownPID else { return nil }
            guard let bundleID = state.bundleID,
                  let trigger = config.triggerApps.first(where: { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame })
            else { return nil }
            return Match(
                app: MeetingMachine.MeetingApp(
                    bundleID: bundleID,
                    name: state.name ?? trigger.resolvedSlug,
                    slug: trigger.resolvedSlug,
                    pid: state.pid
                ),
                input: state.isRunningInput,
                output: state.isRunningOutput
            )
        }
    }
}
