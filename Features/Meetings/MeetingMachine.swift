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
        ///
        /// `app` is carried for one reason: the recording was stopped by hand, and whichever way
        /// the question is answered the process has to be remembered afterwards — see
        /// `settled`. It goes to nil if that application quits while the question is up.
        case savePending(app: MeetingApp?, since: Date, stoppedAt: Date)
        /// This process has been dealt with — refused, stopped by hand, deleted, or cut off by
        /// the length limit. Nothing it does raises a prompt until it lets both devices go.
        case declined(pid: Int32)

        /// The same state in the three terms the menu bar is written in.
        ///
        /// A function of the state and nothing else, so it belongs here rather than in the
        /// coordinator: there is nothing about it that needs a folder, a capture or a clock,
        /// and everything about it that is easy to get wrong at one of the five states.
        public var activity: Activity {
            switch self {
            // A stop prompt is still a recording: the capture is running, and the menu's
            // "stop" is one of the ways to answer it.
            case .recording(_, let since, _, _, _), .stopOffered(_, let since, _, _, _):
                .recording(since: since)
            case .savePending:
                .awaitingAnswer
            // A refusal is at rest as far as the menu goes: the manual start is exactly what
            // the owner reaches for after refusing one by mistake. Whether this coordinator
            // may be *rebuilt* is a different question with a different answer here — see
            // `MeetingCoordinator.canBeRebuilt`.
            case .idle, .declined:
                .ready
            }
        }
    }

    /// What the menu bar may offer about meetings right now.
    public enum Activity: Equatable, Sendable {
        case ready
        /// Something is being recorded, and this is when it started — the elapsed time in the
        /// menu item comes from here rather than from a clock the menu keeps for itself.
        case recording(since: Date)
        /// A prompt owns the decision until it is answered. There is nothing to start, because
        /// the machine ignores it in this state, and nothing to stop, because the capture is
        /// already closed — so the menu offers neither rather than an item that does nothing.
        case awaitingAnswer
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
            state = Self.settled(app)
            return [
                .stopCapture(at: at, reason: .manual),
                .discardDraft,
                .blockDictation(false),
                .hide(after: 0),
            ]

        case (.recording(let app, let since, let confirmed, _, _), .stopPressed(let at)):
            if confirmed {
                state = Self.settled(app)
                return [
                    .stopCapture(at: at, reason: .manual),
                    .keepDraft,
                    .blockDictation(false),
                    .hide(after: 0),
                ]
            }
            state = .savePending(app: app, since: since, stoppedAt: at)
            return [
                .stopCapture(at: at, reason: .manual),
                .blockDictation(false),
                .show(.savePrompt(duration: at.timeIntervalSince(since))),
            ]

        // Every way out of this state settles the process, because the door into it was a stop
        // by hand: what the owner then said about the folder does not change the fact that they
        // ended this meeting's recording themselves.
        case (.savePending(let app, _, _), .keepPressed):
            state = Self.settled(app)
            return [.keepDraft, .hide(after: 0)]

        case (.savePending(let app, _, _), .deletePressed):
            state = Self.settled(app)
            return [.discardDraft, .hide(after: 0)]

        // A refusal ends two ways and both need the process to be there to end it: empty streams,
        // or an exit — and the coordinator reports an exit once, when the process leaves the
        // list. Spending that one report here and then remembering the process anyway would
        // settle the machine into a refusal nothing can lift, and no meeting would ever be
        // noticed again. Forgetting the application is what keeps the answer below harmless.
        case (.savePending(let app, let since, let stoppedAt), .appExited(let gone, _))
            where gone == app?.pid:
            state = .savePending(app: nil, since: since, stoppedAt: stoppedAt)
            return []

        // The same silence rule as everywhere else, and the same threshold as the stop prompt:
        // an unanswered question is not a refusal, so it saves. Without this the question would
        // simply never end — the recording would stay a draft nobody hands over, and the panel
        // holding it would go on taking the mouse over the Dock for the rest of the day.
        // Deliberately the effects of `keepPressed` above, minus the ones that already ran when
        // this state was entered: the capture is closed and dictation is unblocked by now.
        case (.savePending(let app, _, let stoppedAt), .tick(let now)):
            guard now.timeIntervalSince(stoppedAt) >= limits.autoStop else { return [] }
            state = Self.settled(app)
            return [.keepDraft, .hide(after: 0)]

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

        // The twin of the `.savePending` branch above, and needed for exactly the same reason.
        // This prompt is the one silence raises, so unlike the prompt an exit raises it still
        // carries a live application — until the owner closes the conferencing window while it
        // is up, which is the ordinary end of an ordinary meeting. That exit is reported once and
        // never again, so an answer that went on to remember this process would settle into a
        // refusal nothing can lift: no streams to go free, no second exit. Detection would be
        // dead until a restart, and dead for every other application too, because there is one
        // refusal cell for all of them.
        //
        // The prompt itself stays up: it is still a question about a recording that is still
        // open, and `cause` still names what raised it — the silence, not this exit.
        case (.stopOffered(let app, let since, let confirmed, let offeredAt, let cause), .appExited(let gone, _))
            where gone == app?.pid:
            state = .stopOffered(
                app: nil, since: since, confirmed: confirmed, offeredAt: offeredAt, cause: cause
            )
            return []

        case (.recording(let app, let since, let confirmed, _, let quiet), .tick(let now)):
            if now.timeIntervalSince(since) >= limits.maxMeeting {
                return stopAtLimit(app: app, at: now)
            }
            if let quiet, now.timeIntervalSince(quiet) >= limits.silence {
                return offerStop(app: app, since: since, confirmed: confirmed, at: now, cause: .automatic)
            }
            return collapseStartPromptIfDue(now)

        // The application is gone, so the prompt it raised carries no application: there is
        // nothing left to watch for freed devices, nothing left to report an exit a second time,
        // and therefore nothing an answer below could safely remember. `cause` is what still
        // says why this prompt is up.
        case (.recording(let app, let since, let confirmed, _, _), .appExited(let pid, let at)) where pid == app?.pid:
            return offerStop(app: nil, since: since, confirmed: confirmed, at: at, cause: .appExited)

        case (.stopOffered(let app, let since, _, let offeredAt, let cause), .tick(let now)):
            if now.timeIntervalSince(since) >= limits.maxMeeting {
                return stopAtLimit(app: app, at: now)
            }
            guard now.timeIntervalSince(offeredAt) >= limits.autoStop else { return [] }
            return keepAndFinish(at: now, reason: cause)

        // Answering keeps the cause that raised the prompt rather than calling itself manual:
        // the meeting was already over — the application had quit, or the room had gone quiet —
        // and the click only says what to do with what was recorded.
        case (.stopOffered(_, _, _, _, let cause), .keepPressed(let at)):
            return keepAndFinish(at: at, reason: cause)

        case (.stopOffered(let app, _, _, _, let cause), .deletePressed(let at)):
            state = Self.settled(app)
            return [
                .stopCapture(at: at, reason: cause),
                .discardDraft,
                .blockDictation(false),
                .hide(after: 0),
            ]

        // Unlike the answer above, this is the owner reaching for the menu while the prompt is
        // up: their own decision, not the cause that raised it.
        case (.stopOffered(let app, _, _, _, _), .stopPressed(let at)):
            state = Self.settled(app)
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

    /// Where the machine goes once this meeting has been dealt with.
    ///
    /// Four doors lead here — "no", a stop pressed by hand, "delete", and the length limit — and
    /// they all say the same thing about the same process: this meeting has been settled, and
    /// recording it again is not what anybody wants. The watcher repeats itself once a second and
    /// every repeat reads as "an application has just taken the input", so a state that forgot
    /// would start the meeting over on the next tick: a fresh draft, a prompt that collapses in
    /// thirty seconds, and a recording that runs to the end of the meeting. Deleting is worse
    /// still — the new draft is unconfirmed, and silence saves it — and the limit is worse again,
    /// because nobody is watching by then at all.
    ///
    /// Deliberately not every ending. "Save" on a stop prompt is not a door: that prompt is
    /// raised by the room going quiet, so the devices are already free, and answering it settles
    /// the folder rather than the meeting.
    ///
    /// A recording nothing recognisable was holding — a manual start with no meeting
    /// application, or a prompt whose application has already quit — has no process to remember
    /// and simply comes to rest.
    private static func settled(_ app: MeetingApp?) -> State {
        app.map { State.declined(pid: $0.pid) } ?? .idle
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

    /// The limit is the one door into `.declined` the owner did not walk through, and the one
    /// that needs it most. It exists so a forgotten recording cannot eat the disk — and the
    /// meeting is still going when it fires, with the application still holding both devices, so
    /// a machine that came to rest here would start the next four hours on the very next tick.
    /// The limit would then stop limiting anything and merely chop the recording into
    /// gigabyte-sized pieces, which is the opposite of what it is for.
    private mutating func stopAtLimit(app: MeetingApp?, at now: Date) -> [Effect] {
        state = Self.settled(app)
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
