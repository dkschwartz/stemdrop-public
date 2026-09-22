import Foundation
import os

enum Log {
    static let logger = os.Logger(subsystem: "com.resolutecanvas.stemdrop", category: "app")

    private static let engineLogURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/StemDrop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("engine.log")
    }()

    private static let engineQueue = DispatchQueue(label: "com.resolutecanvas.stemdrop.enginelog")

    static func engine(_ line: String) {
        engineQueue.async {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let entry = "[\(timestamp)] \(line)\n"
            guard let data = entry.data(using: .utf8) else { return }

            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: engineLogURL.path) {
                fileManager.createFile(atPath: engineLogURL.path, contents: nil)
            }

            if let handle = try? FileHandle(forWritingTo: engineLogURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }
}
