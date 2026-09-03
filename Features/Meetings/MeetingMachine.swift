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
        /// running: a meeting that comes back to life must not be cut in two. `confirmed` is
        /// carried over from `.recording` rather than assumed: without it, a revived meeting
        /// would forget whether anybody ever confirmed it, and an unconfirmed draft would end
        /// up saving silently instead of asking.
        ///
        /// `cause` is what raised the prompt — silence, or the application quitting. Carried
        /// because the stop itself always arrives later, as a tick or as an answer, and by then
        /// nothing else remembers why the meeting was thought to be over. Without it every
        /// recording would be filed as "went quiet", including the ones whose application quit,
        /// and the field would never say anything but one thing.
        case stopOffered(
            app: MeetingApp?,
            since: Date,
            confirmed: Bool,
            offeredAt: Date,
            cause: MeetingMetadata.StopReason
        )
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
        case keepPressed(at: Date)
        case deletePressed(at: Date)
        /// Delivered often enough to notice every threshold.
        case tick(Date)
        /// Capture never started: a denied permission, nothing to open. There is no partial
        /// recording to protect, so the draft is thrown away — and a folder that is thrown away
        /// needs no timestamp, which is why this one carries none while its sibling below does.
        case captureFailedAtStart(String)
        /// Capture had already produced audio and then died mid-stream. Spec §10: the recording
        /// stops, but the folder is kept as-is rather than discarded — a transient capture
        /// failure must not cost a meeting that was already forty minutes in.
        case captureFailedWhileRecording(String, at: Date)
    }

    public enum Effect: Equatable, Sendable {
        case startCapture(app: MeetingApp?, at: Date)
        /// Close both files. The folder stays a draft.
        ///
        /// Carries both halves of what `meeting.json` has to say about the ending, so the
        /// coordinator writes down what it was told rather than guessing from the event it just
        /// fed in. Guessing was the first version, and it could not tell an application quitting
        /// from a room going quiet: both finish through the same tick, seconds apart.
        case stopCapture(at: Date, reason: MeetingMetadata.StopReason)
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

        // Also from `.declined`, and that is not a convenience: the manual start is the owner's
        // last resort for when detection let them down, so it may never be the thing that
        // stopped working. Refusing one meeting must not leave the menu item dead.
        case (.idle, .startPressed(let app, let at)), (.declined, .startPressed(let app, let at)):
            state = .recording(app: app, since: at, confirmed: true, promptShown: false, quietSince: nil)
            return [
                .startCapture(app: app, at: at),
                .blockDictation(true),
                .show(.recording(since: at, confirmed: true)),
            ]

        case (.recording(let app, let since, _, _, let quiet), .confirmPressed):
            state = .recording(app: app, since: since, confirmed: true, promptShown: false, quietSince: quiet)
            return [.show(.recording(since: since, confirmed: true))]

        case (.recording(let app, _, _, _, _), .declinePressed(let at)):
            state = app.map { State.declined(pid: $0.pid) } ?? .idle
            return [
                .stopCapture(at: at, reason: .manual),
                .discardDraft,
                .blockDictation(false),
                .hide(after: 0),
            ]

        case (.recording(_, let since, let confirmed, _, _), .stopPressed(let at)):
            if confirmed {
                state = .idle
                return [
                    .stopCapture(at: at, reason: .manual),
                    .keepDraft,
                    .blockDictation(false),
                    .hide(after: 0),
                ]
            }
            state = .savePending(since: since, stoppedAt: at)
            return [
                .stopCapture(at: at, reason: .manual),
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

        // A process that quit lets the devices go without ever saying so — it disappears from
        // the list instead of reporting empty streams. Without this the refusal would outlive
        // the meeting it refused, and nothing would ever bring the machine back to rest.
        case (.declined(let pid), .appExited(let gone, _)) where gone == pid:
            state = .idle
            return []

        case (.recording, .captureFailedAtStart(let message)), (.stopOffered, .captureFailedAtStart(let message)):
            state = .idle
            return [
                .discardDraft,
                .blockDictation(false),
                .show(.failure(message)),
                .hide(after: Self.failureDwell),
            ]

        case (.recording, .captureFailedWhileRecording(let message, let at)),
             (.stopOffered, .captureFailedWhileRecording(let message, let at)):
            state = .idle
            return [
                .stopCapture(at: at, reason: .failure),
                .keepDraft,
                .blockDictation(false),
                .show(.failure(message)),
                .hide(after: Self.failureDwell),
            ]

        case (.recording(let app, let since, let confirmed, let promptShown, let quiet), .streamsChanged(let changed, let input, let output, let at))
            where changed.pid == app?.pid:
            let quietSince = (input || output) ? nil : (quiet ?? at)
            state = .recording(app: app, since: since, confirmed: confirmed, promptShown: promptShown, quietSince: quietSince)
            return []

        case (.stopOffered(let app, let since, let confirmed, _, _), .streamsChanged(let changed, let input, let output, _))
            where changed.pid == app?.pid && (input || output):
            // A meeting that came back to life must not be cut in two: the same file keeps
            // being written, and only the panel changes back. `confirmed` is restored as it
            // was, not forced to true.
            state = .recording(app: app, since: since, confirmed: confirmed, promptShown: false, quietSince: nil)
            return [.show(.recording(since: since, confirmed: confirmed))]

        case (.recording(let app, let since, let confirmed, _, let quiet), .tick(let now)):
            if now.timeIntervalSince(since) >= limits.maxMeeting {
                return stopAtLimit(at: now)
            }
            if let quiet, now.timeIntervalSince(quiet) >= limits.silence {
                return offerStop(app: app, since: since, confirmed: confirmed, at: now, cause: .automatic)
            }
            return collapseStartPromptIfDue(now)

        case (.recording(let app, let since, let confirmed, _, _), .appExited(let pid, let at)) where pid == app?.pid:
            return offerStop(app: app, since: since, confirmed: confirmed, at: at, cause: .appExited)

        case (.stopOffered(_, let since, _, let offeredAt, let cause), .tick(let now)):
            if now.timeIntervalSince(since) >= limits.maxMeeting {
                return stopAtLimit(at: now)
            }
            guard now.timeIntervalSince(offeredAt) >= limits.autoStop else { return [] }
            return keepAndFinish(at: now, reason: cause)

        // Answering keeps the cause that raised the prompt rather than calling itself manual:
        // the meeting was already over — the application had quit, or the room had gone quiet —
        // and the click only says what to do with what was recorded.
        case (.stopOffered(_, _, _, _, let cause), .keepPressed(let at)):
            return keepAndFinish(at: at, reason: cause)

        case (.stopOffered(_, _, _, _, let cause), .deletePressed(let at)):
            state = .idle
            return [
                .stopCapture(at: at, reason: cause),
                .discardDraft,
                .blockDictation(false),
                .hide(after: 0),
            ]

        // Unlike the answer above, this is the owner reaching for the menu while the prompt is
        // up: their own decision, not the cause that raised it.
        case (.stopOffered, .stopPressed(let at)):
            state = .idle
            return [
                .stopCapture(at: at, reason: .manual),
                .keepDraft,
                .blockDictation(false),
                .hide(after: 0),
            ]

        default:
            return []
        }
    }

    private mutating func offerStop(
        app: MeetingApp?,
        since: Date,
        confirmed: Bool,
        at now: Date,
        cause: MeetingMetadata.StopReason
    ) -> [Effect] {
        state = .stopOffered(
            app: app, since: since, confirmed: confirmed, offeredAt: now, cause: cause
        )
        return [.show(.stopPrompt(duration: now.timeIntervalSince(since)))]
    }

    /// Silence saves. The draft flag stops mattering here: an unanswered stop prompt is not a
    /// refusal, and the only thing that deletes is an explicit "delete".
    private mutating func keepAndFinish(
        at now: Date, reason: MeetingMetadata.StopReason
    ) -> [Effect] {
        state = .idle
        return [
            .stopCapture(at: now, reason: reason),
            .keepDraft,
            .blockDictation(false),
            .hide(after: 0),
        ]
    }

    private mutating func stopAtLimit(at now: Date) -> [Effect] {
        state = .idle
        return [
            .stopCapture(at: now, reason: .lengthLimit),
            .keepDraft,
            .blockDictation(false),
            .show(.limitReached),
            .hide(after: Self.failureDwell),
        ]
    }

    private mutating func collapseStartPromptIfDue(_ now: Date) -> [Effect] {
        guard case .recording(let app, let since, let confirmed, true, let quiet) = state,
              now.timeIntervalSince(since) >= limits.startPrompt
        else { return [] }
        state = .recording(app: app, since: since, confirmed: confirmed, promptShown: false, quietSince: quiet)
        return [.show(.recording(since: since, confirmed: confirmed))]
    }
}
