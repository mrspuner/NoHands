import Foundation

/// Everything dictation does, as a pure function of state and event.
///
/// Not one system call lives here: no keyboard, no microphone, no network, no window. Events
/// come in, a list of effects goes out, and the coordinator performs them. That is what makes
/// the whole behaviour — thresholds, latching, cancellation, every failure path — testable
/// without a machine to run it on.
///
/// Failure is not a state. Any failure returns the machine to `idle` and emits the effects
/// that report it, because a resting failure state would need an explicit way out, and a
/// missing way out means dictation stops working until the app is restarted.
public struct DictationMachine: Sendable {
    public struct Limits: Equatable, Sendable {
        public var minimumHold: TimeInterval
        public var maximumRecording: TimeInterval
        public var failureDwell: TimeInterval
        public var successDwell: TimeInterval

        public init(
            minimumHold: TimeInterval,
            maximumRecording: TimeInterval,
            failureDwell: TimeInterval = 3,
            successDwell: TimeInterval = 0.6
        ) {
            self.minimumHold = minimumHold
            self.maximumRecording = maximumRecording
            self.failureDwell = failureDwell
            self.successDwell = successDwell
        }

        // `failureDwell` and `successDwell` are deliberately left at their defaults here rather
        // than read from `config`: unlike the hold and recording thresholds, nothing about them
        // depends on the owner's dictation habits, so there is no reason to make them editable.
        public init(config: DictationConfig) {
            self.init(
                minimumHold: config.minimumHoldSeconds,
                maximumRecording: config.maxRecordingSeconds
            )
        }
    }

    public enum Mode: Equatable, Sendable {
        case held
        case latched
    }

    public enum State: Equatable, Sendable {
        case idle
        /// `announced` is false until the hold has outlasted `minimumHold` — before that the
        /// panel has not appeared and no sound has played.
        case recording(mode: Mode, since: Date, announced: Bool)
        /// The engine has been told to stop; the file has not come back yet.
        case stopping
        case transcribing
        case cleaning(raw: String)
        /// Only exits are `.inserted` and `.insertionFailed`. Escape is deliberately released
        /// on entry rather than on either exit: once cleanup has handed off to `.insert`,
        /// there is nothing left to cancel, and swallowing a keystroke the machine has stopped
        /// listening for would just make it vanish.
        case inserting(cleanupSkipped: String?)
    }

    public enum Event: Equatable, Sendable {
        case fnDown(at: Date)
        case fnUp(at: Date)
        case spaceDown
        case escapeDown
        /// Delivered while recording, often enough to notice both thresholds.
        case tick(Date)
        case recordingStopped(URL)
        case recordingFailed(String)
        case transcribed(String)
        case transcriptionFailed(String)
        case cleaned(String)
        case cleanupFailed(String)
        case inserted
        case insertionFailed(String)
    }

    public enum Sound: Equatable, Sendable {
        case start
        case done
        case error
    }

    public enum Effect: Equatable, Sendable {
        case startRecording
        case stopRecording
        case discardRecording
        /// Cancel whatever is in flight: recognition, cleanup, or — while still `.stopping` —
        /// the recorder finishing its file. In that last case the coordinator must discard the
        /// file once it does arrive rather than send it on to recognition.
        case cancelWork
        case transcribe(URL)
        case clean(String)
        case insert(text: String, cleaned: Bool)
        /// Create-or-update: the panel may already be showing something else, or nothing at
        /// all. A dropped tick can jump straight from an unannounced recording to
        /// `.show(.transcribing)` with no `.show(.recording)` ever having preceded it.
        case show(PanelState)
        /// Must tolerate there being no panel to hide: Escape inside the hold threshold emits
        /// this with `after: 0` even though the panel never appeared.
        case hidePanel(after: TimeInterval)
        case play(Sound)
        /// Which keys the tap must stop passing through to the rest of the system.
        case swallow(space: Bool, escape: Bool)
        /// Hand the finished dictation to `RecentDictations`, which also takes ownership of the
        /// audio file. Emitted only once cleanup has run one way or the other: earlier than
        /// that there is no text worth keeping.
        case remember(raw: String, cleaned: String?)
    }

    public let limits: Limits
    public private(set) var state: State = .idle

    /// True while a meeting is being recorded. Set by the coordinator, not carried as an event:
    /// the meeting machine owns this fact, and mirroring it as dictation state would give two
    /// machines two versions of the same truth. Concurrent microphone capture by both features
    /// is a scenario worth never having to debug, and the owner does not dictate during meetings
    /// anyway.
    public var isBlocked = false

    public init(limits: Limits) {
        self.limits = limits
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .fnDown) where isBlocked:
            return [.show(.blocked)]

        case (.idle, .fnDown(let at)):
            state = .recording(mode: .held, since: at, announced: false)
            return [.startRecording, .swallow(space: true, escape: true)]

        case (.recording(let mode, let since, let announced), .tick(let now)):
            if now.timeIntervalSince(since) >= limits.maximumRecording {
                return stopRecording()
            }
            guard !announced, now.timeIntervalSince(since) >= limits.minimumHold else { return [] }
            state = .recording(mode: mode, since: since, announced: true)
            return [.play(.start), .show(.recording(latched: mode == .latched))]

        case (.recording(.held, let since, _), .fnUp(let at)):
            // Measured from the timestamps rather than from `announced`: a tick that never
            // arrived must not throw away a dictation the owner actually made.
            guard at.timeIntervalSince(since) >= limits.minimumHold else {
                state = .idle
                return [.discardRecording, .swallow(space: false, escape: false)]
            }
            return stopRecording()

        case (.recording(.latched, _, _), .fnUp):
            return []

        case (.recording(.latched, _, _), .fnDown):
            return stopRecording()

        case (.recording(.held, let since, let announced), .spaceDown):
            state = .recording(mode: .latched, since: since, announced: announced)
            var effects: [Effect] = [.swallow(space: false, escape: true)]
            if announced {
                effects.append(.show(.recording(latched: true)))
            }
            return effects

        case (.recording, .escapeDown):
            state = .idle
            return [.discardRecording, .hidePanel(after: 0), .swallow(space: false, escape: false)]

        // The engine refuses at start, not at stop — a missing input device, a denied
        // permission. `failed` already discards the recording (and, through it, stops the
        // clock the coordinator started).
        case (.recording, .recordingFailed(let message)):
            return failed(message)

        case (.stopping, .recordingStopped(let url)):
            state = .transcribing
            return [.transcribe(url)]

        case (.stopping, .recordingFailed(let message)):
            return failed(message)

        case (.stopping, .escapeDown), (.transcribing, .escapeDown), (.cleaning, .escapeDown):
            state = .idle
            return [.cancelWork, .hidePanel(after: 0), .swallow(space: false, escape: false)]

        case (.transcribing, .transcribed(let text)):
            state = .cleaning(raw: text)
            return [.show(.cleaning), .clean(text)]

        case (.transcribing, .transcriptionFailed(let message)):
            return failed(message)

        case (.cleaning(let raw), .cleaned(let text)):
            state = .inserting(cleanupSkipped: nil)
            return [
                .swallow(space: false, escape: false),
                .remember(raw: raw, cleaned: text),
                .show(.inserting(cleanupSkipped: nil)),
                .insert(text: text, cleaned: true),
            ]

        case (.cleaning(let raw), .cleanupFailed(let message)):
            state = .inserting(cleanupSkipped: message)
            return [
                .play(.error),
                .swallow(space: false, escape: false),
                .remember(raw: raw, cleaned: nil),
                .show(.inserting(cleanupSkipped: message)),
                .insert(text: raw, cleaned: false),
            ]

        case (.inserting(let skipped), .inserted):
            state = .idle
            var effects: [Effect] = [.swallow(space: false, escape: false)]
            // The error sound has already played when cleanup was skipped; a success chime on
            // top of it would say the opposite of what happened.
            if skipped == nil {
                effects.append(.play(.done))
            }
            effects.append(.hidePanel(after: limits.successDwell))
            return effects

        case (.inserting, .insertionFailed(let message)):
            return failed(message)

        default:
            return []
        }
    }

    private mutating func stopRecording() -> [Effect] {
        state = .stopping
        return [.stopRecording, .swallow(space: false, escape: true), .show(.transcribing)]
    }

    private mutating func failed(_ message: String) -> [Effect] {
        state = .idle
        // A dictation that ended owns no audio, whichever step it failed at. `discardRecording`
        // is idempotent where there is nothing to discard — the coordinator's deletion uses
        // `try?` and the recorder's `discard()` returns early with no session — so this is safe
        // to emit unconditionally rather than tracked per call site.
        return [
            .discardRecording,
            .play(.error),
            .show(.failure(message)),
            .hidePanel(after: limits.failureDwell),
            .swallow(space: false, escape: false),
        ]
    }
}
