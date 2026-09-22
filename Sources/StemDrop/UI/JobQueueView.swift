import SwiftUI

/// One bordered row per queued/finished job, in a scroll area.
struct JobQueueView: View {
    let jobs: [AudioJob]

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(jobs) { job in
                    JobRowView(job: job)
                }
            }
        }
        .frame(maxHeight: 220)
    }
}

private struct JobRowView: View {
    let job: AudioJob

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.sourceURL.lastPathComponent)
                    .truncationMode(.middle)
                    .lineLimit(1)

                Text(stemList)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ProgressView(value: job.progress)
                    .progressViewStyle(.linear)

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(isFailed ? Color.red : Color.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Image(systemName: symbolName)
                .foregroundStyle(symbolColor)
        }
        .padding(10)
        .borderedBox()
    }

    private var stemList: String {
        if job.kind == .cleanup {
            return "Vocals CLEAN"
        }
        return StemType.allCases
            .filter { job.stems.contains($0) }
            .map(\.displayName)
            .joined(separator: ", ")
    }

    private var isFailed: Bool {
        if case .failed = job.status { return true }
        return false
    }

    private var statusText: String {
        switch job.status {
        case .queued:
            return "Queued"
        case .converting:
            return "Converting…"
        case .separating:
            let verb = job.kind == .cleanup ? "Cleaning" : "Separating"
            return "\(verb)… \(Int((job.progress * 100).rounded())) %"
        case .exporting:
            return "Exporting…"
        case .done:
            return "Done"
        case .failed(let message):
            return message
        }
    }

    private var symbolName: String {
        switch job.status {
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        default: return "clock"
        }
    }

    private var symbolColor: Color {
        switch job.status {
        case .done: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
}
