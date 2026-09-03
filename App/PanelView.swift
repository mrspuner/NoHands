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
    }

    /// The resting strip: just enough to say the application is alive.
    private var resting: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }

    private var active: some View {
        HStack(spacing: 12) {
            if case .recording(let latched) = model.state {
                Levels(values: model.levels)
                if latched {
                    Text("фиксация")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(isFailure ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            if let name = model.frontmostName {
                icon
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 520)
    }

    private var icon: some View {
        Group {
            if let image = model.frontmostIcon {
                Image(nsImage: image).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.dashed").frame(width: 20, height: 20)
            }
        }
    }

    private var isFailure: Bool {
        if case .failure = model.state { return true }
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
