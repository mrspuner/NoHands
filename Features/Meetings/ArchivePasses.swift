import Foundation

/// Runs the summary pass and the naming pass over the archive, one after another, and never lets
/// either kind overlap with the other.
///
/// `MeetingSummarizer.scanArchive` and `SpeakerNaming.scanArchive` each refuse to run over
/// *themselves*, but that guards nothing between the two: calling one and then the other from two
/// different call sites — launch, and a meeting finishing — does not order them against each
/// other. A summary pass already in flight when a naming pass starts suspends for minutes inside
/// the MLX subprocess and then writes back whatever text it read at the start; a rename made in
/// that window is silently erased, and because the rename already updated the row's
/// `renderedName`, the next pass sees no change and never repeats it.
///
/// Carries the same deferred-repeat trick `MeetingSummarizer` uses internally: a request that
/// arrives while a round is already running is not dropped, it is remembered for exactly one more
/// round afterwards, never an overlapping one.
///
/// `afterRound` runs at the end of every round, after the naming pass and not before it: the
/// BigHead agent should receive the file with the summary written and the speaker names already
/// applied, the way the owner will read it, not a half-finished copy that gets rewritten a moment
/// later. Because it sits inside the round, it is serialized with both passes for free.
public actor ArchivePasses {
    private let summarizer: MeetingSummarizer
    private let naming: SpeakerNaming
    private let afterRound: @Sendable () async -> Void
    private var scanning = false
    private var rescanRequested = false

    public init(
        summarizer: MeetingSummarizer,
        naming: SpeakerNaming,
        afterRound: @escaping @Sendable () async -> Void = {}
    ) {
        self.summarizer = summarizer
        self.naming = naming
        self.afterRound = afterRound
    }

    public func scanArchive() async {
        guard !scanning else {
            rescanRequested = true
            return
        }
        scanning = true
        defer { scanning = false }
        repeat {
            rescanRequested = false
            await summarizer.scanArchive()
            await naming.scanArchive()
            await afterRound()
        } while rescanRequested
    }
}
