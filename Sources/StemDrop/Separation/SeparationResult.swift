import Foundation

enum EngineEvent: Equatable {
    case loading
    case progress(Double)
    case stem(StemType, URL)
    case done
    case error(String)
}

enum JSONLinesParser {
    private struct RawEvent: Decodable {
        let event: String
        let fraction: Double?
        let name: String?
        let path: String?
        let message: String?
    }

    static func parse(_ line: String) -> EngineEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let raw = try? JSONDecoder().decode(RawEvent.self, from: data) else { return nil }

        switch raw.event {
        case "loading":
            return .loading
        case "progress":
            guard let fraction = raw.fraction else { return nil }
            return .progress(max(0.0, min(1.0, fraction)))
        case "stem":
            guard let name = raw.name, let stem = StemType(rawValue: name),
                  let path = raw.path else { return nil }
            return .stem(stem, URL(fileURLWithPath: path))
        case "done":
            return .done
        case "error":
            guard let message = raw.message else { return nil }
            return .error(message)
        default:
            return nil
        }
    }
}
