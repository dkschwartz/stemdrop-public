import Foundation

enum StemType: String, CaseIterable, Codable {
    case vocals, drums, bass, guitar, piano, other

    var displayName: String {
        switch self {
        case .vocals: return "Vocals"
        case .drums: return "Drums"
        case .bass: return "Bass"
        case .guitar: return "Guitar"
        case .piano: return "Piano"
        case .other: return "Other"
        }
    }

    var engineName: String {
        rawValue
    }
}
