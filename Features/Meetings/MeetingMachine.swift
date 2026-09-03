import Foundation

/// Everything meeting recording does, as a pure function of state and event.
///
/// Not one system call lives here: no CoreAudio, no ScreenCaptureKit, no file system, no
/// window. Events come in, a list of effects goes out, and the coordinator performs them.
///
/// Two rules run through the whole type and explain most of its shape:
/// - the draft records from the first second, before anybody answered, because the opening
///   minutes of a meeting are the ones worth having;
/// - silence never deletes. Only an explicit refusal does.
public struct MeetingMachine: Sendable {
    public struct Limits: Equatable, Sendable {
        /// How long both devices stay free before the meeting looks finished.
        public var silence: TimeInterval
        /// How long the stop prompt waits for an answer before saving by itself.
        public var autoStop: TimeInterval
        /// How long the start prompt stays up before collapsing to the marker.
        public var startPrompt: TimeInterval
        /// Hard stop, so a forgotten recording cannot eat the disk.
        public var maxMeeting: TimeInterval

        public init(silence: TimeInterval, autoStop: TimeInterval, startPrompt: TimeInterval, maxMeeting: TimeInterval) {
            self.silence = silence
            self.autoStop = autoStop
            self.startPrompt = startPrompt
            self.maxMeeting = maxMeeting
        }

        public init(config: MeetingsConfig) {
            self.init(
                silence: config.silenceSeconds,
                autoStop: config.autoStopSeconds,
                startPrompt: config.startPromptSeconds,
                maxMeeting: config.maxMeetingSeconds
            )
        }
    }

    /// The meeting application, as the watcher recognised it. `pid` is what makes "the same
    /// meeting" answerable: bundle identifiers repeat across launches, process identifiers do
    /// not.
    public struct MeetingApp: Equatable, Sendable {
        public var bundleID: String
        public var name: String
        public var slug: String
        public var pid: Int32

        public init(bundleID: String, name: String, slug: String, pid: Int32) {
            self.bundleID = bundleID
            self.name = name
            self.slug = slug
            self.pid = pid
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        /// Recording. `confirmed` decides what happens at the end: a confirmed recording is
        /// saved silently, a draft asks. `quietSince` is when both devices last went free.
        case recording(app: MeetingApp?, since: Date, confirmed: Bool, promptShown: Bool, quietSince: Date?)
        /// Both devices have been free long enough that the meeting looks over. Capture keeps
        /// running: a meeting that comes back to life must not be cut in two.
        case stopOffered(app: MeetingApp?, since: Date, offeredAt: Date)
        /// Capture is stopped, the folder is still a draft, and the answer decides its fate.
        case savePending(since: Date, stoppedAt: Date)
        /// This process was refused. Nothing it does raises a prompt until it lets both
        /// devices go.
        case declined(pid: Int32)
    }

    public enum Event: Equatable, Sendable {
        /// Delivered by the watcher for trigger applications only.
        case streamsChanged(app: MeetingApp, input: Bool, output: Bool, at: Date)
        case appExited(pid: Int32, at: Date)
        case startPressed(app: MeetingApp?, at: Date)
        case stopPressed(at: Date)
        case confirmPressed(at: Date)
        case declinePressed(at: Date)
        case keepPressed
        case deletePressed
        /// Delivered often enough to notice every threshold.
        case tick(Date)
        case captureFailed(String)
    }

    public enum Effect: Equatable, Sendable {
        case startCapture(app: MeetingApp?, at: Date)
        /// Close both files. The folder stays a draft.
        case stopCapture
        /// Rename the draft folder to its final name — the atomic hand-off to phase 2б.
        case keepDraft
        case discardDraft
        case show(MeetingPanelState)
        /// One case rather than two: `hide` and `hide(after:)` would be a redeclaration, and
        /// the dictation machine already spells the immediate case as `after: 0`.
        case hide(after: TimeInterval)
        /// True while a meeting is being recorded: fn must not start a dictation.
        case blockDictation(Bool)
    }

    /// How long a named failure stays on the panel. Not configurable: nothing about it depends
    /// on the owner's habits.
    static let failureDwell: TimeInterval = 5

    public let limits: Limits
    public private(set) var state: State = .idle

    public init(limits: Limits) {
        self.limits = limits
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .streamsChanged(let app, let input, let output, let at)) where input || output:
            state = .recording(app: app, since: at, confirmed: false, promptShown: true, quietSince: nil)
            return [
                .startCapture(app: app, at: at),
                .blockDictation(true),
                .show(.startPrompt(appName: app.name)),
            ]

        case (.idle, .startPressed(let app, let at)):
            state = .recording(app: app, since: at, confirmed: true, promptShown: false, quietSince: nil)
            return [
                .startCapture(app: app, at: at),
                .blockDictation(true),
                .show(.recording(since: at, confirmed: true)),
            ]

        case (.recording(let app, let since, _, _, let quiet), .confirmPressed):
            state = .recording(app: app, since: since, confirmed: true, promptShown: false, quietSince: quiet)
            return [.show(.recording(since: since, confirmed: true))]

        case (.recording(let app, _, _, _, _), .declinePressed):
            state = app.map { State.declined(pid: $0.pid) } ?? .idle
            return [.stopCapture, .discardDraft, .blockDictation(false), .hide(after: 0)]

        case (.recording(_, let since, let confirmed, _, _), .stopPressed(let at)):
            if confirmed {
                state = .idle
                return [.stopCapture, .keepDraft, .blockDictation(false), .hide(after: 0)]
            }
            state = .savePending(since: since, stoppedAt: at)
            return [
                .stopCapture,
                .blockDictation(false),
                .show(.savePrompt(duration: at.timeIntervalSince(since))),
            ]

        case (.savePending, .keepPressed):
            state = .idle
            return [.keepDraft, .hide(after: 0)]

        case (.savePending, .deletePressed):
            state = .idle
            return [.discardDraft, .hide(after: 0)]

        case (.declined(let pid), .streamsChanged(let app, let input, let output, _))
            where app.pid == pid:
            if !input && !output {
                state = .idle
            }
            return []

        case (.recording, .captureFailed(let message)), (.stopOffered, .captureFailed(let message)):
            state = .idle
            return [
                .discardDraft,
                .blockDictation(false),
                .show(.failure(message)),
                .hide(after: Self.failureDwell),
            ]

        default:
            return []
        }
    }
}
