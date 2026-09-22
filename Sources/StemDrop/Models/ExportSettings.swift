import Foundation
import AVFoundation

enum OutputFormat: String {
    case wav
    case aiff
    case mp3

    var fileExtension: String {
        switch self {
        case .wav: return "wav"
        case .aiff: return "aiff"
        case .mp3: return "mp3"
        }
    }
}

enum WAVBitDepth: String {
    case int16
    case int24
    case float32
}

enum NamingStyle: String {
    case dash
    case bracket
}

enum ConflictPolicy: String {
    case number
    case replace
    case ask
}

enum OutputMode: String {
    case root
    case sameFolder
}

struct ExportSettings {
    var format: OutputFormat = .aiff
    var bitDepth: WAVBitDepth = .int24
    /// When set, `AudioExporter.write` pads with zeros or truncates the
    /// output so it has exactly this many frames (see SPEC.md §7 Daniel note).
    var targetFrameCount: AVAudioFramePosition? = nil
    var normalize = false
    var trimTrailingSilence = false
    /// When non-nil, `AudioExporter.write` tags the finished file with this
    /// metadata (see SPEC.md §12/§13).
    var metadata: StemMetadata? = nil
}
