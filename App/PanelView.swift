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

/// The panel's background: a slightly darkened material with a lit border.
///
/// Shape, corner radius, border width and period are taken from the reference this was designed
/// against — `beam.jakubantalik.com`, mode "rotate", size "md". Two of its themes are used:
/// "mono" at rest, a still grey halo; "sunset" while recording, its warm colours travelling
/// around the border once every 3.1 seconds.
///
/// The motion is deliberately confined to recording. This panel is on screen permanently now,
/// and a continuously animating layer means continuous redraws on a machine that is also
/// running speech recognition — paid for a strip the size of an icon that nobody is looking at.
private struct Surface: View {
    let recording: Bool

    static let cornerRadius: CGFloat = 16
    static let borderWidth: CGFloat = 1
    /// One full turn, from the reference.
    static let period: Double = 3.1

    /// The reference's "sunset" border colours, in the order they sit around the edge.
    private static let sunset: [Color] = [
        Color(red: 1.00, green: 0.31, blue: 0.20),
        Color(red: 1.00, green: 0.63, blue: 0.16),
        Color(red: 1.00, green: 0.47, blue: 0.24),
        Color(red: 1.00, green: 0.78, blue: 0.20),
        Color(red: 1.00, green: 0.39, blue: 0.31),
    ]

    /// "mono" is the same geometry desaturated and blurred harder — in the reference, the
    /// colours drop to about a seventh of their opacity and the blur grows from one or two
    /// pixels to a dozen.
    private static let mono: [Color] = [
        Color(white: 0.75), Color(white: 0.45), Color(white: 0.85), Color(white: 0.40),
    ]

    var body: some View {
        ZStack {
            shape
                .fill(.regularMaterial)
            // Slightly darker than the Dock, so the strip reads as a deliberate object rather
            // than as a smudge of whatever is behind it.
            shape
                .fill(Color.black.opacity(0.18))
            if recording {
                TimelineView(.animation) { timeline in
                    border(colors: Self.sunset, angle: Self.angle(at: timeline.date), blur: 2, opacity: 0.95)
                }
            } else {
                border(colors: Self.mono, angle: .degrees(0), blur: 6, opacity: 0.5)
            }
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    private func border(colors: [Color], angle: Angle, blur: CGFloat, opacity: Double) -> some View {
        // The gradient is drawn across the whole surface, then masked down to the border ring:
        // blurring first and masking after is what keeps the glow soft without bleeding it
        // across the panel's face.
        AngularGradient(colors: colors + [colors[0]], center: .center, angle: angle)
            .blur(radius: blur)
            .opacity(opacity)
            .mask(shape.strokeBorder(lineWidth: Self.borderWidth))
    }

    private static func angle(at date: Date) -> Angle {
        let turn = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return .degrees(turn * 360)
    }
}

/// The live level while recording. No honest progress exists for the stages after it — neither
/// recognition nor a single API call reports any — so those get a caption instead of a bar
/// that would be pretending.
private struct Levels: View {
    let values: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: max(3, CGFloat(value) * 22))
            }
        }
        .frame(height: 22)
    }
}
