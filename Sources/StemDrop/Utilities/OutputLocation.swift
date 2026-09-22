import Foundation

/// Resolves and creates the folder a job's stems get written into
/// (SPEC.md §13).
enum OutputLocation {
    /// `AppPreferences` is `@MainActor`-isolated, so this hops there to
    /// read `outputMode`/`outputRootPath` before touching the filesystem.
    /// `baseName`, when supplied, overrides the song name used in the
    /// "<baseName> STEM SPLIT" folder (root mode only); defaults to
    /// `source`'s own base name.
    @MainActor
    static func folder(
        for source: URL,
        prefs: AppPreferences,
        baseName: String? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory: URL

        switch prefs.outputMode {
        case .sameFolder:
            directory = source.deletingLastPathComponent()
        case .root:
            let root = URL(fileURLWithPath: prefs.outputRootPath, isDirectory: true)
            let baseRoot = fileManager.fileExists(atPath: root.path) ? root : source.deletingLastPathComponent()
            let baseName = baseName ?? source.deletingPathExtension().lastPathComponent
            directory = baseRoot.appendingPathComponent("\(baseName) STEM SPLIT", isDirectory: true)
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StemDropError.outputNotWritable
        }

        return directory
    }

    /// Resolves the folder a Vocal Cleanup job's output gets written into.
    /// If the source stem was itself produced by a split (its parent folder
    /// is named "<song> STEM SPLIT"), the cleaned vocal is saved right next
    /// to it there. Otherwise falls back to the normal `folder(for:prefs:)`
    /// rules.
    @MainActor
    static func cleanupFolder(
        for source: URL,
        prefs: AppPreferences,
        fileManager: FileManager = .default
    ) throws -> URL {
        let parent = source.deletingLastPathComponent()
        if parent.lastPathComponent.hasSuffix(" STEM SPLIT") {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  fileManager.isWritableFile(atPath: parent.path)
            else {
                throw StemDropError.outputNotWritable
            }
            return parent
        }

        return try folder(
            for: source,
            prefs: prefs,
            baseName: FileNaming.songBaseName(fromStem: source),
            fileManager: fileManager
        )
    }
}
