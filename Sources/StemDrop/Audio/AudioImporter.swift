import Foundation
import AVFoundation
import UniformTypeIdentifiers

enum AudioImporter {
    static let maxFileSize: Int64 = 2 * 1_024 * 1_024 * 1_024 // 2 GB
    static let diskSpaceMultiplier: Int64 = 3

    static func validate(_ url: URL) throws {
        let fileManager = FileManager.default

        guard fileManager.isReadableFile(atPath: url.path) else {
            throw StemDropError.unreadableAudio
        }

        guard let resourceValues = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey]) else {
            throw StemDropError.unreadableAudio
        }

        guard let contentType = resourceValues.contentType, contentType.conforms(to: .audio) else {
            throw StemDropError.unreadableAudio
        }

        guard let fileSize = resourceValues.fileSize, Int64(fileSize) <= maxFileSize else {
            throw StemDropError.unreadableAudio
        }

        do {
            _ = try AVAudioFile(forReading: url)
        } catch {
            throw StemDropError.unreadableAudio
        }
    }

    static func checkDiskSpace(for url: URL, tempDir: URL) throws {
        guard let sourceSizeValue = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw StemDropError.unreadableAudio
        }
        let sourceSize = Int64(sourceSizeValue)

        guard let freeSpaceValue = try? tempDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else {
            throw StemDropError.diskFull
        }

        guard freeSpaceValue >= sourceSize * diskSpaceMultiplier else {
            throw StemDropError.diskFull
        }
    }
}
