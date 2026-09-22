import Foundation

@MainActor
final class AppPreferences: ObservableObject {
    private enum Keys {
        static let selectedStems = "selectedStems"
        static let outputFormat = "outputFormat"
        static let wavBitDepth = "wavBitDepth"
        static let namingStyle = "namingStyle"
        static let conflictPolicy = "conflictPolicy"
        static let revealInFinder = "revealInFinder"
        static let playSound = "playSound"
        static let deleteTempImmediately = "deleteTempImmediately"
        static let modelInstalled = "modelInstalled"
        static let modelRevision = "modelRevision"
        static let preserveOriginalLength = "preserveOriginalLength"
        static let normalizeOutput = "normalizeOutput"
        static let trimTrailingSilence = "trimTrailingSilence"
        static let albumTag = "albumTag"
        static let outputRootPath = "outputRootPath"
        static let outputMode = "outputMode"
        static let cleanupReseparate = "cleanupReseparate"
        static let cleanupReseparatePasses = "cleanupReseparatePasses"
        static let cleanupGate = "cleanupGate"
        static let cleanupGateThreshold = "cleanupGateThreshold"
        static let cleanupDenoise = "cleanupDenoise"
        static let cleanupDenoiseAmount = "cleanupDenoiseAmount"
    }

    private let defaults: UserDefaults

    @Published var selectedStems: Set<StemType> {
        didSet {
            defaults.set(selectedStems.map(\.rawValue), forKey: Keys.selectedStems)
        }
    }

    @Published var outputFormat: OutputFormat {
        didSet {
            defaults.set(outputFormat.rawValue, forKey: Keys.outputFormat)
        }
    }

    @Published var wavBitDepth: WAVBitDepth {
        didSet {
            defaults.set(wavBitDepth.rawValue, forKey: Keys.wavBitDepth)
        }
    }

    @Published var namingStyle: NamingStyle {
        didSet {
            defaults.set(namingStyle.rawValue, forKey: Keys.namingStyle)
        }
    }

    @Published var conflictPolicy: ConflictPolicy {
        didSet {
            defaults.set(conflictPolicy.rawValue, forKey: Keys.conflictPolicy)
        }
    }

    @Published var revealInFinder: Bool {
        didSet {
            defaults.set(revealInFinder, forKey: Keys.revealInFinder)
        }
    }

    @Published var playSound: Bool {
        didSet {
            defaults.set(playSound, forKey: Keys.playSound)
        }
    }

    @Published var deleteTempImmediately: Bool {
        didSet {
            defaults.set(deleteTempImmediately, forKey: Keys.deleteTempImmediately)
        }
    }

    @Published var modelInstalled: Bool {
        didSet {
            defaults.set(modelInstalled, forKey: Keys.modelInstalled)
        }
    }

    /// Which set of model weights has been downloaded. Bumped whenever the
    /// required models change so existing installs re-download (e.g. revision 2
    /// adds the fine-tuned `htdemucs_ft` quality model).
    @Published var modelRevision: Int {
        didSet {
            defaults.set(modelRevision, forKey: Keys.modelRevision)
        }
    }

    @Published var preserveOriginalLength: Bool {
        didSet {
            defaults.set(preserveOriginalLength, forKey: Keys.preserveOriginalLength)
        }
    }

    @Published var normalizeOutput: Bool {
        didSet {
            defaults.set(normalizeOutput, forKey: Keys.normalizeOutput)
        }
    }

    @Published var trimTrailingSilence: Bool {
        didSet {
            defaults.set(trimTrailingSilence, forKey: Keys.trimTrailingSilence)
        }
    }

    @Published var albumTag: String {
        didSet {
            defaults.set(albumTag, forKey: Keys.albumTag)
        }
    }

    @Published var outputRootPath: String {
        didSet {
            defaults.set(outputRootPath, forKey: Keys.outputRootPath)
        }
    }

    @Published var outputMode: OutputMode {
        didSet {
            defaults.set(outputMode.rawValue, forKey: Keys.outputMode)
        }
    }

    @Published var cleanupReseparate: Bool {
        didSet {
            defaults.set(cleanupReseparate, forKey: Keys.cleanupReseparate)
        }
    }

    @Published var cleanupReseparatePasses: Int {
        didSet {
            defaults.set(cleanupReseparatePasses, forKey: Keys.cleanupReseparatePasses)
        }
    }

    @Published var cleanupGate: Bool {
        didSet {
            defaults.set(cleanupGate, forKey: Keys.cleanupGate)
        }
    }

    @Published var cleanupGateThreshold: Double {
        didSet {
            defaults.set(cleanupGateThreshold, forKey: Keys.cleanupGateThreshold)
        }
    }

    @Published var cleanupDenoise: Bool {
        didSet {
            defaults.set(cleanupDenoise, forKey: Keys.cleanupDenoise)
        }
    }

    @Published var cleanupDenoiseAmount: Double {
        didSet {
            defaults.set(cleanupDenoiseAmount, forKey: Keys.cleanupDenoiseAmount)
        }
    }

    /// Assembles the six cleanup preferences into a single `CleanupSettings`
    /// value for `JobQueue`/`PythonEngineRunner`.
    var cleanupSettings: CleanupSettings {
        CleanupSettings(
            reseparate: cleanupReseparate,
            reseparatePasses: cleanupReseparatePasses,
            gate: cleanupGate,
            gateThreshold: cleanupGateThreshold,
            denoise: cleanupDenoise,
            denoiseAmount: cleanupDenoiseAmount
        )
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedStems = defaults.array(forKey: Keys.selectedStems) as? [String]
        let stems = storedStems.map { rawValues in
            Set(rawValues.compactMap(StemType.init(rawValue:)))
        }
        self.selectedStems = stems ?? [.drums]

        let storedFormat = defaults.string(forKey: Keys.outputFormat).flatMap(OutputFormat.init(rawValue:))
        self.outputFormat = storedFormat ?? .aiff

        let storedBitDepth = defaults.string(forKey: Keys.wavBitDepth).flatMap(WAVBitDepth.init(rawValue:))
        self.wavBitDepth = storedBitDepth ?? .int24

        let storedNamingStyle = defaults.string(forKey: Keys.namingStyle).flatMap(NamingStyle.init(rawValue:))
        self.namingStyle = storedNamingStyle ?? .dash

        let storedConflictPolicy = defaults.string(forKey: Keys.conflictPolicy).flatMap(ConflictPolicy.init(rawValue:))
        self.conflictPolicy = storedConflictPolicy ?? .number

        self.revealInFinder = (defaults.object(forKey: Keys.revealInFinder) as? Bool) ?? true
        self.playSound = (defaults.object(forKey: Keys.playSound) as? Bool) ?? true
        self.deleteTempImmediately = (defaults.object(forKey: Keys.deleteTempImmediately) as? Bool) ?? true
        self.modelInstalled = (defaults.object(forKey: Keys.modelInstalled) as? Bool) ?? false
        self.modelRevision = defaults.integer(forKey: Keys.modelRevision)
        self.preserveOriginalLength = (defaults.object(forKey: Keys.preserveOriginalLength) as? Bool) ?? true
        self.normalizeOutput = (defaults.object(forKey: Keys.normalizeOutput) as? Bool) ?? false
        self.trimTrailingSilence = (defaults.object(forKey: Keys.trimTrailingSilence) as? Bool) ?? false
        self.albumTag = defaults.string(forKey: Keys.albumTag) ?? "ISOLATED TRACKS"
        self.outputRootPath = defaults.string(forKey: Keys.outputRootPath)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path

        let storedOutputMode = defaults.string(forKey: Keys.outputMode).flatMap(OutputMode.init(rawValue:))
        self.outputMode = storedOutputMode ?? .root

        self.cleanupReseparate = (defaults.object(forKey: Keys.cleanupReseparate) as? Bool) ?? true
        let storedPasses = defaults.object(forKey: Keys.cleanupReseparatePasses) as? Int
        self.cleanupReseparatePasses = storedPasses ?? 1
        self.cleanupGate = (defaults.object(forKey: Keys.cleanupGate) as? Bool) ?? true
        let storedGateThreshold = defaults.object(forKey: Keys.cleanupGateThreshold) as? Double
        self.cleanupGateThreshold = storedGateThreshold ?? 0.5
        self.cleanupDenoise = (defaults.object(forKey: Keys.cleanupDenoise) as? Bool) ?? true
        let storedDenoiseAmount = defaults.object(forKey: Keys.cleanupDenoiseAmount) as? Double
        self.cleanupDenoiseAmount = storedDenoiseAmount ?? 0.5
    }
}
