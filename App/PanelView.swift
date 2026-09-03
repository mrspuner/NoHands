import Dictation
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 520)
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
