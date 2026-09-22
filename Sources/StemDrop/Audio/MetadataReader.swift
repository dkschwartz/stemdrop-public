import Foundation
import AVFoundation

enum MetadataReader {
    static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frameCount = file.length
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return Double(frameCount) / sampleRate
    }

    /// Source file length, converted from its own sample rate to
    /// `atSampleRate` (e.g. 44100 Hz, the engine's working rate) and rounded
    /// to the nearest frame.
    static func frameCount(of url: URL, atSampleRate: Double) -> AVAudioFramePosition? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sourceSampleRate = file.fileFormat.sampleRate
        guard sourceSampleRate > 0 else { return nil }
        let scaled = Double(file.length) * (atSampleRate / sourceSampleRate)
        return AVAudioFramePosition(scaled.rounded())
    }

    /// Reads artist/album-artist/title/year tags off the source file, for
    /// stamping exported stems (SPEC.md §12). Best-effort: any field that
    /// can't be read comes back nil rather than throwing.
    static func read(_ url: URL) async -> (artist: String?, albumArtist: String?, title: String?, year: String?) {
        let asset = AVURLAsset(url: url)

        var artist: String?
        var title: String?
        var year: String?
        var albumArtist: String?

        if let commonItems = try? await asset.load(.commonMetadata) {
            for item in commonItems {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyArtist:
                    if let value = try? await item.load(.stringValue) { artist = value }
                case .commonKeyTitle:
                    if let value = try? await item.load(.stringValue) { title = value }
                case .commonKeyCreationDate:
                    if let value = try? await item.load(.stringValue), year == nil {
                        year = extractYear(from: value)
                    }
                default:
                    break
                }
            }
        }

        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                guard let items = try? await asset.loadMetadata(for: format) else { continue }
                for item in items {
                    guard let identifier = item.identifier?.rawValue ?? (item.key as? String) else { continue }
                    if identifier.contains("TPE2") || identifier.lowercased().contains("albumartist") {
                        if let value = try? await item.load(.stringValue) { albumArtist = value }
                    }
                    if year == nil, identifier.contains("TYER") || identifier.contains("TDRC") {
                        if let value = try? await item.load(.stringValue) {
                            year = extractYear(from: value)
                        }
                    }
                }
            }
        }

        return (artist, albumArtist, title, year)
    }

    private static func extractYear(from string: String) -> String? {
        let digits = string.prefix(while: { $0.isNumber })
        return digits.count == 4 ? String(digits) : (string.isEmpty ? nil : string)
    }
}
