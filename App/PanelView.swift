import Dictation
import Meetings
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        Group {
            // Dictation first, and only then a meeting: dictation is what the owner is doing
            // this second, it lasts seconds, and a meeting prompt it covers comes back by
            // itself the moment it collapses.
            if model.state != nil {
                active
            } else if let meeting = model.meeting {
                MeetingContent(model: model, state: meeting)
            } else {
                resting
            }
        }
        // Both views hang from the bottom of the window, so expanding and collapsing grows and
        // shrinks upward from one fixed line above the Dock instead of moving the strip.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// The resting strip: just enough to say the application is alive.
    private var resting: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Surface(recording: false))
    }

    private var active: some View {
        HStack(spacing: 12) {
            // Naming the frontmost application next to a failure reads as "the text went there" —
            // it did not. Shown in every other expanded state, where it is accurate.
            if !endsWithoutText {
                icon
            }
            if case .recording(let latched) = model.state {
                Levels(values: model.levels)
                if latched {
                    // The word it replaces cost width the row does not have, and an icon says
                    // "pinned" without needing to be read.
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(isFailure ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            if let hz = model.narrowbandHz {
                Text("узкая полоса, \(Int(hz / 1000)) кГц")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Surface(recording: isRecording))
        .frame(maxWidth: 520)
    }

    private var icon: some View {
        Group {
            if let image = model.frontmostIcon {
                Image(nsImage: image).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.dashed").resizable().frame(width: 20, height: 20)
            }
        }
    }

    private var isFailure: Bool {
        if case .failure = model.state { return true }
        return false
    }

    /// The states after which nothing is pasted anywhere — the refusal to dictate over a
    /// meeting is one of them, exactly like a failure. Exhaustive rather than defaulted so a
    /// new state has to be thought about here rather than quietly getting an icon that lies.
    private var endsWithoutText: Bool {
        switch model.state {
        case .failure, .blocked: true
        case .recording, .transcribing, .cleaning, .inserting, nil: false
        }
    }

    private var isRecording: Bool {
        if case .recording = model.state { return true }
        return false
    }

    private var caption: String {
        switch model.state {
        case .transcribing: return "распознаю"
        case .cleaning: return "чищу"
        case .inserting(let skipped):
            guard let skipped else { return "вставляю" }
            return "вставляю без чистки: \(skipped)"
        case .failure(let message): return message
        case .blocked: return "идёт запись созвона"
        case .recording, nil: return ""
        }
    }
}

/// The meeting side of the panel.
///
/// Only a prompt expands the panel. Sixteen points above the Dock is not a target anyone hits
/// with a mouse, so a question with buttons has to grow into something clickable — while a
/// recording, which runs for an hour, stays the strip it was: a wide panel standing open that
/// long would be in the way, and the timer answers the one question that comes up meanwhile,
/// which is whether this is being recorded at all. The two short-lived notices expand as well:
/// they are on screen for five seconds and have to be readable in them.
private struct MeetingContent: View {
    /// Held, not observed: `PanelView` above already redraws on every change, and the one
    /// thing read out of the model here — where a pressed button sends its answer — is not
    /// published and must be read at the moment of the press rather than captured earlier.
    let model: PanelModel
    let state: MeetingPanelState

    var body: some View {
        switch state {
        case .recording(let since, _):
            strip(since: since)
        case .startPrompt(let appName):
            prompt(
                "Записать созвон в \(appName)?",
                yes: ("Записать", .confirm),
                no: ("Нет", .decline)
            )
        case .stopPrompt(let duration):
            prompt(
                "Встреча кончилась? Сохранить запись \(Self.length(duration))",
                yes: ("Сохранить", .keep),
                no: ("Удалить", .delete)
            )
        case .savePrompt(let duration):
            prompt(
                "Сохранить запись \(Self.length(duration))?",
                yes: ("Сохранить", .keep),
                no: ("Удалить", .delete)
            )
        case .orphanFound(let duration):
            prompt(
                "Найдена незавершённая запись \(Self.length(duration))",
                yes: ("Сохранить", .keep),
                no: ("Удалить", .delete)
            )
        case .limitReached:
            notice("Достигнут предел длительности, запись сохранена", failed: false)
        case .failure(let message):
            notice(message, failed: true)
        }
    }

    /// How long the recording being asked about ran. Minutes, because the question is whether
    /// an hour of meeting is worth keeping and seconds are noise at that scale — but never
    /// "0 мин": rounding a recording that exists down to nothing would answer the question
    /// wrongly, and the owner has no way to see that something was in fact recorded.
    private static func length(_ duration: TimeInterval) -> String {
        let minutes = ElapsedTime.minutes(duration)
        return minutes < 1 ? "меньше минуты" : "\(minutes) мин"
    }

    /// The collapsed strip while a meeting records: a red light and a clock.
    ///
    /// The surface is the resting one, not the lit theme dictation uses. That theme animates
    /// every frame, and its own author confined it to recording precisely because this window
    /// is permanent — a dictation lasts seconds, a meeting an hour, and an hour of continuous
    /// redraw next to speech recognition is not a price a strip the size of an icon is worth.
    private func strip(since: Date) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
            Elapsed(since: since)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Surface(recording: false))
    }

    private func prompt(
        _ text: String,
        yes: (String, MeetingCoordinator.Answer),
        no: (String, MeetingCoordinator.Answer)
    ) -> some View {
        // No spacer between the question and the answers: a row that hugs its text keeps the
        // panel as narrow as what it has to say, the way every other state of it does.
        HStack(spacing: 10) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            PromptButton(title: yes.0, prominent: true) { model.onMeetingAnswer?(yes.1) }
            PromptButton(title: no.0, prominent: false) { model.onMeetingAnswer?(no.1) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Surface(recording: false))
        .frame(maxWidth: 520)
    }

    private func notice(_ text: String, failed: Bool) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(failed ? Color.red : Color.secondary)
            .lineLimit(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Surface(recording: false))
            .frame(maxWidth: 520)
    }
}

/// How long the meeting has been recording. Ticks once a second rather than on every frame:
/// this is the one thing on the panel that can be up for an hour.
private struct Elapsed: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(ElapsedTime.clock(context.date.timeIntervalSince(since)))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// One answer to a prompt.
///
/// `.plain` rather than a stock button: the stock one draws its own light chrome, which on this
/// dark surface reads as a piece of a different window. The panel never becomes key, so a
/// button here is never the focused control and never draws a focus ring — the shape is the
/// only thing saying "this can be clicked".
private struct PromptButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(prominent ? 0.22 : 0.10)))
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
    }
}

/// One blurred patch of colour sitting on the border.
///
/// Position is a unit point within the surface; values outside 0…1 are the reference's own and
/// place a patch deliberately past the edge, so only its inner shoulder reaches the border.
private struct Blob {
    let color: Color
    let x: Double
    let y: Double
    let width: CGFloat
    let height: CGFloat
}

private extension Color {
    /// The reference states its colours in 0…255 `rgb()`; keeping them in that form makes them
    /// checkable against it line by line.
    static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255)
    }
}

/// The panel's background: a dark surface inside a border made of moving coloured patches.
///
/// Geometry, colours, corner radius, border width and period come from the reference this was
/// designed against — `beam.jakubantalik.com`, mode "rotate", size "md" — down to the nine
/// patches and their percentage positions. Its animation is three things at once, named by its
/// own keyframes: `beam-spin`, `beam-breathe`, `beam-travel`. Spin and breathe are reproduced
/// here; they are what makes it read as alive rather than as a drawn line.
///
/// Two themes: "mono" at rest, the same nine patches in grey and still; "sunset" while
/// recording, warm and in motion.
///
/// The motion is deliberately confined to recording. This panel is on screen permanently now,
/// and a continuously animating layer means continuous redraws on a machine that is also
/// running speech recognition — paid for a strip the size of an icon that nobody is looking at.
private struct Surface: View {
    let recording: Bool

    static let cornerRadius: CGFloat = 16
    static let borderWidth: CGFloat = 1
    /// One full turn, from the reference.
    static let spinPeriod: Double = 3.1
    /// Deliberately not a multiple of the spin, so the two never fall into lockstep and the
    /// border keeps looking unrepetitive.
    static let breathePeriod: Double = 2.3

    /// The reference's "sunset" patches, in its own order.
    static let sunset: [Blob] = [
        Blob(color: .rgb(255, 80, 50), x: 0.330, y: -0.074, width: 70, height: 40),
        Blob(color: .rgb(255, 160, 40), x: 0.120, y: -0.050, width: 60, height: 35),
        Blob(color: .rgb(255, 120, 60), x: 0.021, y: 0.683, width: 40, height: 70),
        Blob(color: .rgb(255, 200, 50), x: 0.021, y: 0.683, width: 20, height: 35),
        Blob(color: .rgb(255, 100, 80), x: 0.744, y: 1.000, width: 180, height: 32),
        Blob(color: .rgb(255, 180, 60), x: 0.550, y: 1.000, width: 85, height: 26),
        Blob(color: .rgb(255, 60, 60), x: 0.939, y: 0.000, width: 74, height: 32),
        Blob(color: .rgb(255, 140, 50), x: 1.000, y: 0.271, width: 26, height: 42),
        Blob(color: .rgb(255, 90, 70), x: 1.000, y: 0.271, width: 52, height: 48),
    ]

    /// The same nine patches in the reference's "mono" greys.
    private static let mono: [Blob] = [
        Blob(color: .rgb(180, 180, 180), x: 0.330, y: -0.074, width: 70, height: 40),
        Blob(color: .rgb(140, 140, 140), x: 0.120, y: -0.050, width: 60, height: 35),
        Blob(color: .rgb(160, 160, 160), x: 0.021, y: 0.683, width: 40, height: 70),
        Blob(color: .rgb(130, 130, 130), x: 0.021, y: 0.683, width: 20, height: 35),
        Blob(color: .rgb(170, 170, 170), x: 0.744, y: 1.000, width: 180, height: 32),
        Blob(color: .rgb(150, 150, 150), x: 0.550, y: 1.000, width: 85, height: 26),
        Blob(color: .rgb(190, 190, 190), x: 0.939, y: 0.000, width: 74, height: 32),
        Blob(color: .rgb(145, 145, 145), x: 1.000, y: 0.271, width: 26, height: 42),
        Blob(color: .rgb(165, 165, 165), x: 1.000, y: 0.271, width: 52, height: 48),
    ]

    /// How strongly each layer shows, from the reference's `md` preset on a dark surface.
    /// The crisp edge is the *faintest* of the three; most of what the eye reads as the effect
    /// is the inner glow spilling in from the patches sitting on the perimeter.
    struct Layers {
        let stroke: Double
        let inner: Double
        /// The reference's `innerShadow`: a white hairline just inside the edge.
        let hairline: Double

        static let sunset = Layers(stroke: 0.55, inner: 0.5, hairline: 0.27)
        /// The reference halves every layer for "mono"; at rest this is meant to be barely there.
        static let mono = Layers(stroke: 0.22, inner: 0.2, hairline: 0.14)
    }

    /// From the reference's `md` preset.
    static let saturation: Double = 1.2
    /// How far the glow is allowed to reach in from the edge. Nothing is drawn outside the
    /// box at all: a halo around a strip that floats over other windows reads as a smudge on
    /// the screen rather than as part of the panel.
    static let glowReach: CGFloat = 20
    /// The veil that settles the glow into the fill away from the edge. Its strength is a
    /// function of distance to the *edge*, not to the centre: this panel is far wider than it
    /// is tall, and a radial gradient would darken the side edges and the top edge by
    /// different amounts even though both are edges. An inset shape softened by a blur is a
    /// true distance-from-edge ramp — nothing at the edge, most of the way there a couple of
    /// points in, full by a third of the way to the middle.
    static let veilInset: CGFloat = 1
    static let veilSoftness: CGFloat = 5

    var body: some View {
        if recording {
            TimelineView(.animation) { timeline in
                let seconds = timeline.date.timeIntervalSinceReferenceDate
                surface(
                    Self.sunset,
                    spin: .degrees(turn(seconds, Self.spinPeriod) * 360),
                    seconds: seconds,
                    layers: .sunset
                )
            }
        } else {
            // Still, and therefore free: at rest this is a strip the size of an icon.
            surface(Self.mono, spin: .degrees(0), seconds: nil, layers: .mono)
        }
    }

    /// Three layers over the fill. The patches sit on the perimeter, so the same field masked
    /// to a band inside the edge rather than to the ring alone is what turns a border into a
    /// glow reaching inward — the patches' inner shoulders are all that shows.
    private func surface(
        _ blobs: [Blob], spin: Angle, seconds: Double?, layers: Layers
    ) -> some View {
        ZStack {
            shape.fill(.regularMaterial)
            shape.fill(Color.black.opacity(0.55))

            // The glow, held to a soft band `glowReach` deep. Masked twice on purpose: the
            // blurred band shapes how far it reaches and how softly it fades, and the second
            // mask guarantees not a pixel of it lands outside the box.
            field(blobs, spin: spin, seconds: seconds, blur: 12)
                .opacity(layers.inner)
                .mask(shape.strokeBorder(lineWidth: Self.glowReach).blur(radius: 8))
                .mask(shape)

            // Only while recording: at rest the glow is faint enough to need no settling, and
            // the strip is too small to have a middle worth veiling.
            if recording {
                shape
                    .fill(Color.black.opacity(0.55))
                    .mask(
                        shape
                            .inset(by: Self.veilInset)
                            .fill(Color.white)
                            .blur(radius: Self.veilSoftness)
                    )
            }

            shape.strokeBorder(Color.white.opacity(layers.hairline), lineWidth: 0.5)

            field(blobs, spin: spin, seconds: seconds, blur: 1.5)
                .opacity(layers.stroke)
                .mask(shape.strokeBorder(lineWidth: Self.borderWidth))
        }
        .saturation(Self.saturation)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    /// The nine patches laid out across the surface, spun and breathing. Every layer draws the
    /// same field and differs only in how hard it is blurred and how far it is masked.
    private func field(
        _ blobs: [Blob], spin: Angle, seconds: Double?, blur: CGFloat
    ) -> some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(blobs.indices, id: \.self) { index in
                    let blob = blobs[index]
                    Ellipse()
                        .fill(blob.color)
                        .frame(width: blob.width, height: blob.height)
                        .opacity(breath(at: seconds, phase: Double(index) * 0.37))
                        .position(
                            x: blob.x * geometry.size.width,
                            y: blob.y * geometry.size.height
                        )
                }
            }
            .blur(radius: blur)
            .rotationEffect(spin)
        }
    }

    /// Each patch fades in and out on its own phase, which is the reference's `beam-breathe`.
    /// Still patches when there is no clock — the resting theme does not animate.
    private func breath(at seconds: Double?, phase: Double) -> Double {
        guard let seconds else { return 1 }
        let turns = turn(seconds, Self.breathePeriod) + phase
        return 0.55 + 0.45 * (0.5 + 0.5 * sin(turns * 2 * .pi))
    }

    private func turn(_ seconds: Double, _ period: Double) -> Double {
        seconds.truncatingRemainder(dividingBy: period) / period
    }
}

/// The live level while recording. No honest progress exists for the stages after it — neither
/// recognition nor a single API call reports any — so those get a caption instead of a bar
/// that would be pretending.
///
/// White: the border already carries all the colour the panel needs, and a voice reads more
/// clearly as plain light than as a second gradient competing with the frame.
private struct Levels: View {
    let values: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: max(3, CGFloat(value) * 22))
            }
        }
        .frame(height: 22)
    }
}
