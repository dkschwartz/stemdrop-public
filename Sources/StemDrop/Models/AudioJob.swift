import Foundation

enum JobStatus: Equatable {
    case queued
    case converting
    case separating
    case exporting
    case done
    case failed(String)

    /// Queued or in progress (not finished either way).
    var isActive: Bool {
        switch self {
        case .queued, .converting, .separating, .exporting: return true
        case .done, .failed: return false
        }
    }
}

enum JobKind: Equatable, Sendable {
    case split
    case cleanup
}

struct AudioJob: Identifiable {
    let id: UUID
    let sourceURL: URL
    let stems: Set<StemType>
    var status: JobStatus
    var progress: Double
    var outputs: [URL]
    var kind: JobKind = .split
    var cleanup: CleanupSettings? = nil
}
