import Foundation

enum TemporaryFiles {
    private static var rootDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("StemDrop", isDirectory: true)
    }

    static func dir(for jobID: UUID) throws -> URL {
        let dir = rootDir.appendingPathComponent(jobID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cleanup(jobID: UUID) {
        let dir = rootDir.appendingPathComponent(jobID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    static func cleanupAll() {
        try? FileManager.default.removeItem(at: rootDir)
    }
}
