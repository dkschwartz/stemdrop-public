import Foundation

enum FileNaming {
    static func outputURL(
        source: URL,
        stem: StemType,
        style: NamingStyle,
        conflict: ConflictPolicy,
        format: OutputFormat = .aiff,
        directory: URL? = nil,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        outputURL(
            source: source,
            label: stem.displayName,
            style: style,
            conflict: conflict,
            format: format,
            directory: directory,
            fileExists: fileExists
        )
    }

    /// Same naming rules as the stem-based overload above, but for a plain
    /// label (e.g. "Vocals CLEAN") that isn't a `StemType`. `baseName`, when
    /// supplied, overrides the name derived from `source` (e.g. so a
    /// "Song - Vocals.aiff" input yields "Song - Vocals CLEAN.aiff" instead
    /// of "Song - Vocals - Vocals CLEAN.aiff" — see `songBaseName(fromStem:)`).
    static func outputURL(
        source: URL,
        label: String,
        style: NamingStyle,
        conflict: ConflictPolicy,
        format: OutputFormat = .aiff,
        directory: URL? = nil,
        baseName: String? = nil,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let directory = directory ?? source.deletingLastPathComponent()
        let baseName = baseName ?? source.deletingPathExtension().lastPathComponent
        let stemName = label
        let ext = format.fileExtension

        func nameWithoutExtension(suffix: String) -> String {
            switch style {
            case .dash:
                return "\(baseName) - \(stemName)\(suffix)"
            case .bracket:
                return "\(baseName) [\(stemName)]\(suffix)"
            }
        }

        let plainURL = directory
            .appendingPathComponent(nameWithoutExtension(suffix: ""))
            .appendingPathExtension(ext)

        switch conflict {
        case .replace, .ask:
            return plainURL
        case .number:
            guard fileExists(plainURL) else {
                return plainURL
            }
            var counter = 2
            while true {
                let candidate = directory
                    .appendingPathComponent(nameWithoutExtension(suffix: " \(counter)"))
                    .appendingPathExtension(ext)
                if !fileExists(candidate) {
                    return candidate
                }
                counter += 1
            }
        }
    }

    /// Strips a trailing stem suffix — " - <Stem>" or " [<Stem>]", optionally
    /// followed by " <n>" (from `ConflictPolicy.number`) — off a stem file's
    /// base name, so a cleanup pass on "Song - Vocals.aiff" can be named
    /// relative to "Song" rather than "Song - Vocals". Falls back to the
    /// plain base name when no stem suffix is found.
    static func songBaseName(fromStem source: URL) -> String {
        let base = source.deletingPathExtension().lastPathComponent

        for stem in StemType.allCases {
            let name = NSRegularExpression.escapedPattern(for: stem.displayName)
            if let range = base.range(of: " - \(name)( \\d+)?$", options: .regularExpression) {
                return String(base[..<range.lowerBound])
            }
            if let range = base.range(of: " \\[\(name)\\]( \\d+)?$", options: .regularExpression) {
                return String(base[..<range.lowerBound])
            }
        }

        return base
    }
}
