import Foundation

enum StemDropError: LocalizedError {
    case unreadableAudio
    case separationFailed
    case diskFull
    case modelDownloadFailed
    case outputNotWritable

    var errorDescription: String? {
        switch self {
        case .unreadableAudio:
            return "Could not read this audio file."
        case .separationFailed:
            return "Stem separation failed.\nTry converting the song to WAV or M4A."
        case .diskFull:
            return "Not enough free disk space."
        case .modelDownloadFailed:
            return "Could not download the separation model. Check your connection and try again."
        case .outputNotWritable:
            return "Can't save next to the original file. Choose a different output folder."
        }
    }
}
