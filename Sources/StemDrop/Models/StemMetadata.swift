import Foundation

/// Tags written into an exported stem file (SPEC.md §12/§13).
struct StemMetadata: Sendable {
    var artist: String?
    var album: String
    var title: String
    var year: String?
}
