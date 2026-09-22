import Foundation

/// Shared engine-location resolution, used by anything that spawns the
/// bundled Python sidecar (separation, model download, MP3 encoding).
enum EnginePaths {
    /// Engine location precedence: bundled app resources → dev override
    /// env var → package-relative Resources dir (for `swift run`).
    static func pythonExecutable() -> URL {
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("engine/bin/python3")
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
        }
        if let envPath = ProcessInfo.processInfo.environment["STEMDROP_ENGINE_PYTHON"],
           !envPath.isEmpty {
            return URL(fileURLWithPath: envPath)
        }
        return packageRoot.appendingPathComponent("Resources/engine/bin/python3")
    }

    /// Used when running the executable from the package directory during development.
    private static var packageRoot: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }
}
