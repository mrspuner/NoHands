import AppKit
import Core
import Dictation
import Meetings

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenu?
    private var coordinator: DictationCoordinator?
    private var meetings: MeetingCoordinator?
    /// Built once and reconfigured in place afterwards, never rebuilt — see its own `config` for
    /// why a rebuild on every reload would be unsafe rather than merely wasteful.
    private var meetingQueue: MeetingQueue?
    /// Unlike `meetingQueue`, this one *is* recreated every time `rebuildMeetings` runs, as a
    /// side effect of that method always rebuilding this whole block rather than only at launch.
    /// The old timer is invalidated first, so a reload never leaves two of them sweeping.
    private var sweepTimer: Timer?
    private var buildTask: Task<Void, Never>?
    private let panel = PanelWindow()
    /// Owned here rather than by the coordinator: a config reload rebuilds the coordinator, and
    /// the owner's last ten dictations must not vanish with it.
    private let recent = RecentDictations()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = StatusMenu(
            recent: recent,
            meetingActivity: { [weak self] in self?.meetings?.activity },
            onStartMeeting: { [weak self] in self?.meetings?.startPressed() },
            onStopMeeting: { [weak self] in self?.meetings?.stopPressed() },
            onQuit: { [weak self] in
                self?.coordinator?.stop()
                // A recording in flight is deliberately left where it is: quitting mid-meeting
                // leaves the draft a crash would, and the same prompt picks it up next launch.
                // `MeetingCoordinator.stop` says why in full.
                self?.meetings?.stop()
            },
            // Re-reading means rebuilding: the thresholds live in the machine, the prompt and
            // the model live in the client, and none of them is consulted again after start.
            onReloadConfig: { [weak self] in
                guard let self, let menu = self.statusMenu else { return }
                self.startBuild(menu: menu)
            }
        )
        statusMenu = menu

        // The panel is built before any coordinator, so the buttons on a meeting prompt are
        // pointed at whichever one exists when they are pressed rather than at one captured now.
        panel.setMeetingAnswer { [weak self] answer in self?.meetings?.answer(answer) }

        // The frontmost application is read live rather than captured, so the panel can never
        // name a receiver that stopped being one. `NSWorkspace` posts on its own notification
        // centre, not the default one.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [panel] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                panel.setFrontmost(name: app?.localizedName, icon: app?.icon)
            }
        }
        let current = NSWorkspace.shared.frontmostApplication
        panel.setFrontmost(name: current?.localizedName, icon: current?.icon)

        startBuild(menu: menu)
    }

    // A build already in flight is ignored rather than cancelled: `ParakeetTranscriber.load`
    // downloads and loads a model with no cancellation point of its own, so cancelling the task
    // would not actually stop the work in progress — it would just leave two builds racing to
    // finish, with no guarantee which coordinator survives. Ignoring keeps exactly one build
    // running at a time; the owner can retry the reload once it settles. Distinct from
    // "Загружаю модель…" so a click that did nothing cannot be mistaken for one that worked.
    private func startBuild(menu: StatusMenu) {
        guard buildTask == nil else {
            menu.setStatus("Уже перезагружаюсь, подождите…")
            return
        }
        buildTask = Task { [weak self] in
            // Meetings are rebuilt first and awaited before the dictation build starts, rather
            // than synchronously before this task the way they used to be: `rebuildMeetings` now
            // has to cross into `MeetingQueue`'s isolation to reconfigure it in place, and that
            // crossing needs `await`. It still costs nothing next to loading a 470 MB model, so
            // meetings are ready long before `buildCoordinator` finishes — the property this
            // ordering exists to keep.
            let meetingsNote = await self?.rebuildMeetings() ?? nil
            await self?.buildCoordinator(menu: menu, meetingsNote: meetingsNote)
            self?.buildTask = nil
        }
    }

    /// Builds the meeting coordinator, or returns the line saying why it did not.
    ///
    /// `async` because reconfiguring `MeetingQueue` in place (`update(config:makeTranscriber:)`)
    /// requires crossing into its actor, which building a fresh one every time did not. See
    /// `startBuild` for how the caller keeps that crossing from delaying meetings behind the
    /// dictation model load.
    ///
    /// A line for the status line rather than something shown here: the panel is where a
    /// meeting reports what became of a recording, and a settings file that could not be read
    /// is not that — it is the same "why is this not working" that the dictation build already
    /// answers in the menu, and the menu is where the owner has just clicked to reload.
    private func rebuildMeetings() async -> String? {
        // Never around anything the old coordinator is still holding — a recording, an
        // unanswered prompt, a refusal. `canBeRebuilt` is deliberately not the same question as
        // "what may the menu offer": it says so itself, at length, and this line asking the
        // wrong one of the two is how a refused meeting ended up recorded anyway.
        if let meetings, !meetings.canBeRebuilt {
            return "созвоны: настройки применятся после встречи или ответа на подсказку"
        }
        let config: MeetingsConfig
        do {
            config = try MeetingsConfig.loadOrCreate()
        } catch {
            // Whatever was running keeps running: a config that cannot be read is a reason to
            // keep the settings that worked, not to stop noticing meetings altogether.
            return "созвоны: \(error.localizedDescription)"
        }
        meetings?.stop()

        let dictationLanguage = (try? DictationConfig.loadOrCreate())?.language
        // The queue loads the model itself, with the same language as dictation: one machine
        // listens to the same speech, and a second key in the config would mean two settings
        // for one ear.
        let makeTranscriber: @Sendable () async throws -> any TimedTranscriber = {
            try await ParakeetTranscriber.load(language: dictationLanguage)
        }
        // Built once and afterwards only re-configured. «Перечитать конфиг» is the single reload
        // path for every setting in this application, and a backlog drain can run for hours, so
        // replacing the actor here would routinely leave two of them working the same folder —
        // see `MeetingQueue.config` for what that costs. `startBuild`'s task guard exists for the
        // same reason on the dictation side.
        if let existing = meetingQueue {
            await existing.update(config: config, makeTranscriber: makeTranscriber)
        } else {
            meetingQueue = MeetingQueue(
                config: config,
                makeTranscriber: makeTranscriber,
                report: { [panel] outcome in
                    Task { @MainActor in
                        panel.show(notice: MeetingNotice.forOutcome(outcome))
                        panel.hideNotice(after: MeetingNotice.dwell)
                    }
                }
            )
        }
        guard let queue = meetingQueue else { return nil }
        let built = MeetingCoordinator(
            config: config,
            showPanel: { [panel] state in panel.show(meeting: state) },
            hidePanel: { [panel] delay in panel.hideMeeting(after: delay) },
            onNarrowbandInput: { [panel] hz in panel.setMeetingInputWarning(hz: hz) },
            // The one thing dictation must not run alongside: both want the microphone, and the
            // dictated speech would land in the meeting's own track.
            onDictationBlocked: { [weak self] blocked in self?.coordinator?.isBlocked = blocked },
            // And the same rule the other way round, per spec §6: a dictation already under way
            // finishes before a meeting starts recording. Asked live rather than captured — the
            // dictation coordinator is rebuilt by a config reload, and a captured one would go
            // on answering for an object nobody is dictating into.
            isDictating: { [weak self] in self?.coordinator?.isDictating ?? false },
            // The rename in `MeetingCoordinator` is the only hand-off point into phase 2б — see
            // its own comment. Without this, a finished recording would only reach the archive on
            // the next launch's `scanAll`.
            onFolderReady: { url in
                Task { await queue.enqueue(url) }
            }
        )
        // Drafts a crash left behind are found in here: `start` looks for them before it begins
        // polling, and offers the first one on the panel.
        built.start()
        meetings = built

        // A previous timer, if any, must not go on sweeping alongside this one: `rebuildMeetings`
        // runs on every config reload, not just at launch, and an un-invalidated timer would pile
        // up one extra daily sweep per reload for as long as the application keeps running.
        sweepTimer?.invalidate()
        Task {
            // Sweep first. `scanAll` can return before the folders it found have been processed —
            // if a drain is already running it hands them over and exits — so sweeping afterwards
            // would run alongside live processing. Nothing would break, because rotation only
            // touches folders that are already `.processed` and a folder just finished is far too
            // fresh to sweep, but the order that needs no such argument is the better one.
            await queue.sweep()
            await queue.scanAll()
        }
        // The machine is always on, so a once-a-day timer is all the scheduler this needs.
        let timer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { _ in
            Task { await queue.sweep() }
        }
        // `.common`, not the default mode: this file has already paid for the alternative twice,
        // on `MeetingCoordinator`'s poller and `DictationCoordinator`'s ticker — a default-mode
        // timer stops firing while a menu is open, and the menu is one of this application's two
        // surfaces.
        RunLoop.main.add(timer, forMode: .common)
        sweepTimer = timer
        return nil
    }

    /// The menu has one status line and, on a bad day, two things to say on it.
    private static func status(_ dictation: String, _ meetings: String?) -> String {
        [dictation, meetings].compactMap { $0 }.joined(separator: " · ")
    }

    private func buildCoordinator(menu: StatusMenu, meetingsNote: String?) async {
        // Set here, in the one entry point both launch and «Перечитать конфиг» go through: the
        // reload path used to tear the tap down and reload the model for several seconds while
        // the menu still read the old status — "Готов" while dictation was, in fact, dead.
        menu.setStatus("Загружаю модель…")
        coordinator?.stop()
        coordinator = nil
        do {
            let config = try DictationConfig.loadOrCreate()
            // Loaded once and kept resident: 470 MB against 16 GB, and the alternative is
            // paying the load on every dictation, which is when waiting is least acceptable.
            let transcriber = try await ParakeetTranscriber.load(language: config.language)
            // The key is not read here: `DeepSeekClient`'s lazy initializer defers that to the
            // moment cleanup actually runs. Recognition is entirely local and needs no key, so
            // a missing or Keychain-refused key must not keep the hotkey from ever going live —
            // see the initializer's own comment for why this is not hypothetical. A missing key
            // now surfaces as `.cleanupFailed` per spec section 10: raw text inserted, reason
            // named on the panel, error sound played.
            let cleaner = DeepSeekClient(
                model: config.model, prompt: config.prompt, timeout: config.timeoutSeconds
            )
            let coordinator = DictationCoordinator(
                config: config,
                recorder: MicrophoneRecorder(),
                transcriber: transcriber,
                cleaner: cleaner,
                inserter: TextInserter(),
                recent: recent,
                sounds: SoundPlayer(sounds: config.sounds),
                showPanel: { [panel] state in panel.show(state) },
                hidePanel: { [panel] delay in panel.hide(after: delay) },
                onLevel: { [panel] level in
                    // `onLevel` is `@Sendable`: DictationCoordinator already hops to the main
                    // queue before invoking it, so this is the same "known to be on the main
                    // actor, provably or not" situation the coordinator itself expresses with
                    // `MainActor.assumeIsolated` for its timer and key-event delivery.
                    MainActor.assumeIsolated {
                        panel.setLevel(level)
                    }
                },
                onNarrowbandInput: { [panel] hz in panel.setInputWarning(hz: hz) }
            )
            try coordinator.start()
            // This coordinator is new; the meeting it must not run alongside can be older than
            // it. `blockDictation(true)` fired when that recording started, at a coordinator
            // that no longer exists, and nothing will repeat it until the meeting ends.
            if let activity = meetings?.activity, case .recording = activity {
                coordinator.isBlocked = true
            }
            self.coordinator = coordinator
            menu.setStatus(Self.status("Готов", meetingsNote))
            // Reaching the Keychain raises an authorization dialog the first time this
            // application reads the key. Doing it here, once the hotkey is already live, puts
            // that dialog where waiting costs nothing — rather than in the middle of the first
            // dictation, after the owner has already spoken. It cannot fail the launch: see
            // `warmUp()`.
            await cleaner.warmUp()
        } catch {
            menu.setStatus(Self.status(error.localizedDescription, meetingsNote))
        }
    }
}
