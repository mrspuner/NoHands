import Dictation
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        Group {
            if model.state == nil {
                resting
            } else {
                active
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
            if !isFailure {
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
        case .recording, nil: return ""
        }
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
        let bloom: Double
        /// The reference's `innerShadow`: a white hairline just inside the edge.
        let hairline: Double

        static let sunset = Layers(stroke: 0.26, inner: 0.42, bloom: 0.24, hairline: 0.27)
        /// The reference halves every layer for "mono"; at rest this is meant to be barely there.
        static let mono = Layers(stroke: 0.13, inner: 0.21, bloom: 0.12, hairline: 0.14)
    }

    /// From the reference's `md` preset.
    static let saturation: Double = 1.2

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

    /// Four layers, in the reference's own order. The patches sit on the perimeter, so masking
    /// the same field to the whole shape rather than to the ring is what turns a border into a
    /// glow that reaches inward — the patches' inner shoulders are all that shows.
    private func surface(
        _ blobs: [Blob], spin: Angle, seconds: Double?, layers: Layers
    ) -> some View {
        ZStack {
            field(blobs, spin: spin, seconds: seconds, blur: 18)
                .opacity(layers.bloom)

            shape.fill(.regularMaterial)
            shape.fill(Color.black.opacity(0.55))

            field(blobs, spin: spin, seconds: seconds, blur: 10)
                .opacity(layers.inner)
                .mask(shape)

            shape.strokeBorder(Color.white.opacity(layers.hairline), lineWidth: 0.5)

            field(blobs, spin: spin, seconds: seconds, blur: 1.2)
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
/// Lit in the border's own colours, so the loudest thing on the panel and its frame belong to
/// the same object.
private struct Levels: View {
    let values: [Float]

    var body: some View {
        LinearGradient(
            colors: Surface.sunset.map(\.color),
            startPoint: .leading,
            endPoint: .trailing
        )
        .mask(bars)
        .frame(width: CGFloat(values.count) * 5 - 2, height: 22)
    }

    private var bars: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Capsule()
                    .frame(width: 3, height: max(3, CGFloat(value) * 22))
            }
        }
        .frame(height: 22)
    }
}
