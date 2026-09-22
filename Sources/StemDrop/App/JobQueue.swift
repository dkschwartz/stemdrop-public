import Foundation
import AppKit

/// Runs at most one separation job at a time (D8), processing jobs strictly
/// in the order they were enqueued. Reports every state change back through
/// a `@MainActor` callback so `AppState` can update its published `jobs`.
actor JobQueue {
    typealias StatusHandler = @MainActor @Sendable (UUID, JobStatus, Double, [URL]) -> Void

    private var pending: [AudioJob] = []
    private var isRunning = false
    private var modelEnsured = false

    private let prefs: AppPreferences
    private let modelManager: any ModelInstalling
    private let converter: AudioConverting
    private let separator: StemSeparator
    private let cleaner: VocalCleaner
    private let exporter: AudioExporting
    private let validate: @Sendable (URL) throws -> Void
    private let checkDiskSpace: @Sendable (URL, URL) throws -> Void
    private let onUpdate: StatusHandler

    init(
        prefs: AppPreferences,
        modelManager: any ModelInstalling,
        converter: AudioConverting,
        separator: StemSeparator,
        cleaner: VocalCleaner,
        exporter: AudioExporting,
        validate: @escaping @Sendable (URL) throws -> Void = { try AudioImporter.validate($0) },
        checkDiskSpace: @escaping @Sendable (URL, URL) throws -> Void = { try AudioImporter.checkDiskSpace(for: $0, tempDir: $1) },
        onUpdate: @escaping StatusHandler
    ) {
        self.prefs = prefs
        self.modelManager = modelManager
        self.converter = converter
        self.separator = separator
        self.cleaner = cleaner
        self.exporter = exporter
        self.validate = validate
        self.checkDiskSpace = checkDiskSpace
        self.onUpdate = onUpdate
    }

    /// Adds a job to the end of the queue and (re)starts the processing loop
    /// if it isn't already running.
    func enqueue(_ job: AudioJob) {
        pending.append(job)
        report(job.id, status: job.status, progress: job.progress, outputs: job.outputs)
        Task { await runLoopIfNeeded() }
    }

    private func runLoopIfNeeded() async {
        guard !isRunning else { return }
        isRunning = true
        while !pending.isEmpty {
            let job = pending.removeFirst()
            await process(job)
        }
        isRunning = false
    }

    /// Prefs/tag reads and the base `ExportSettings` that are identical
    /// whether the job is a stem split or a vocal cleanup.
    private struct ExportContext {
        let namingStyle: NamingStyle
        let conflictPolicy: ConflictPolicy
        let outputFormat: OutputFormat
        var settings: ExportSettings
        let sourceTags: (artist: String?, albumArtist: String?, title: String?, year: String?)
        let sourceBaseName: String
        let sourceTitle: String
        let stemArtist: String?
        let albumTag: String
        let revealInFinder: Bool
    }

    private func buildExportContext(for job: AudioJob) async -> ExportContext {
        let namingStyle = await prefs.namingStyle
        let conflictPolicy = await prefs.conflictPolicy
        let outputFormat = await prefs.outputFormat
        let bitDepth = await prefs.wavBitDepth
        let preserveOriginalLength = await prefs.preserveOriginalLength
        let normalizeOutput = await prefs.normalizeOutput
        let trimTrailingSilence = await prefs.trimTrailingSilence
        let albumTag = await prefs.albumTag
        let revealInFinder = await prefs.revealInFinder

        var settings = ExportSettings(format: outputFormat, bitDepth: bitDepth)
        settings.normalize = normalizeOutput
        settings.trimTrailingSilence = trimTrailingSilence
        if preserveOriginalLength {
            // Preserve the length of the ORIGINAL source, not the
            // converted/resampled input.wav, per SPEC.md §7 Daniel note.
            settings.targetFrameCount = MetadataReader.frameCount(
                of: job.sourceURL,
                atSampleRate: AudioConverter.engineSampleRate
            )
        }

        // Read source tags once per job (SPEC.md §12).
        let sourceTags = await MetadataReader.read(job.sourceURL)
        let sourceBaseName = job.sourceURL.deletingPathExtension().lastPathComponent
        let sourceTitle = sourceTags.title ?? sourceBaseName
        let stemArtist = sourceTags.artist ?? sourceTags.albumArtist

        return ExportContext(
            namingStyle: namingStyle,
            conflictPolicy: conflictPolicy,
            outputFormat: outputFormat,
            settings: settings,
            sourceTags: sourceTags,
            sourceBaseName: sourceBaseName,
            sourceTitle: sourceTitle,
            stemArtist: stemArtist,
            albumTag: albumTag,
            revealInFinder: revealInFinder
        )
    }

    private func process(_ job: AudioJob) async {
        let jobID = job.id
        do {
            try validate(job.sourceURL)

            let workDir = try TemporaryFiles.dir(for: jobID)
            try checkDiskSpace(job.sourceURL, workDir)

            report(jobID, status: .converting, progress: 0, outputs: [])
            let inputWAV = try await converter.toEngineWAV(job.sourceURL, into: workDir)
            report(jobID, status: .converting, progress: 0.05, outputs: [])

            if !modelEnsured {
                try await modelManager.ensureInstalled()
                modelEnsured = true
            }

            let outputs: [URL]
            switch job.kind {
            case .split:
                outputs = try await processSplit(job, jobID: jobID, inputWAV: inputWAV, workDir: workDir)
            case .cleanup:
                outputs = try await processCleanup(job, jobID: jobID, inputWAV: inputWAV, workDir: workDir)
            }

            TemporaryFiles.cleanup(jobID: jobID)

            report(jobID, status: .done, progress: 1.0, outputs: outputs)

            // Start/end sounds are played once per batch by AppState.
            let revealInFinder = await prefs.revealInFinder
            if revealInFinder {
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
            }
        } catch {
            TemporaryFiles.cleanup(jobID: jobID)

            let message: String
            if let stemDropError = error as? StemDropError {
                message = stemDropError.errorDescription ?? StemDropError.separationFailed.errorDescription ?? ""
            } else {
                Log.engine("job \(jobID) failed: \(error)")
                message = StemDropError.separationFailed.errorDescription ?? ""
            }
            report(jobID, status: .failed(message), progress: 0, outputs: [])
        }
    }

    private func processSplit(_ job: AudioJob, jobID: UUID, inputWAV: URL, workDir: URL) async throws -> [URL] {
        report(jobID, status: .separating, progress: 0.05, outputs: [])
        let onUpdate = self.onUpdate
        let separator = self.separator
        let stemResults = try await separator.separate(
            inputWAV: inputWAV,
            stems: job.stems,
            workDir: workDir,
            progress: { fraction in
                let mapped = 0.05 + (fraction * 0.9)
                Task { @MainActor in onUpdate(jobID, .separating, mapped, []) }
            }
        )

        report(jobID, status: .exporting, progress: 0.95, outputs: [])

        var context = await buildExportContext(for: job)
        let outputDir = try await OutputLocation.folder(for: job.sourceURL, prefs: prefs)

        let stemsOrdered = StemType.allCases.filter { job.stems.contains($0) }
        let total = max(stemsOrdered.count, 1)
        var outputs: [URL] = []

        for (index, stem) in stemsOrdered.enumerated() {
            guard let stemURL = stemResults[stem] else { continue }
            let destination = FileNaming.outputURL(
                source: job.sourceURL,
                stem: stem,
                style: context.namingStyle,
                conflict: context.conflictPolicy,
                format: context.outputFormat,
                directory: outputDir
            )
            context.settings.metadata = StemMetadata(
                artist: context.stemArtist,
                album: context.albumTag,
                title: "\(context.sourceTitle) - \(stem.displayName)",
                year: context.sourceTags.year
            )
            try exporter.write(stemWAV: stemURL, to: destination, settings: context.settings)
            outputs.append(destination)
            let fraction = 0.95 + (Double(index + 1) / Double(total) * 0.05)
            report(jobID, status: .exporting, progress: fraction, outputs: outputs)
        }

        return outputs
    }

    private func processCleanup(_ job: AudioJob, jobID: UUID, inputWAV: URL, workDir: URL) async throws -> [URL] {
        report(jobID, status: .separating, progress: 0.05, outputs: [])
        let onUpdate = self.onUpdate
        let cleaner = self.cleaner
        let cleanupSettings = job.cleanup ?? CleanupSettings()
        let vocalsURL = try await cleaner.clean(
            inputWAV: inputWAV,
            settings: cleanupSettings,
            workDir: workDir,
            progress: { fraction in
                let mapped = 0.05 + (fraction * 0.9)
                Task { @MainActor in onUpdate(jobID, .separating, mapped, []) }
            }
        )

        report(jobID, status: .exporting, progress: 0.95, outputs: [])

        var context = await buildExportContext(for: job)
        // The cleanup output must never get a gain change or silence trim
        // applied — it's the same audio the engine already tuned, just
        // re-encoded, regardless of what the SPLIT tab's prefs say.
        context.settings.normalize = false
        context.settings.trimTrailingSilence = false
        let outputDir = try await OutputLocation.cleanupFolder(for: job.sourceURL, prefs: prefs)

        let destination = FileNaming.outputURL(
            source: job.sourceURL,
            label: "Vocals CLEAN",
            style: context.namingStyle,
            conflict: context.conflictPolicy,
            format: context.outputFormat,
            directory: outputDir,
            baseName: FileNaming.songBaseName(fromStem: job.sourceURL)
        )
        context.settings.metadata = StemMetadata(
            artist: context.stemArtist,
            album: context.albumTag,
            title: "\(context.sourceTitle) - Vocals CLEAN",
            year: context.sourceTags.year
        )
        try exporter.write(stemWAV: vocalsURL, to: destination, settings: context.settings)
        let outputs = [destination]
        report(jobID, status: .exporting, progress: 1.0, outputs: outputs)

        return outputs
    }

    private func report(_ jobID: UUID, status: JobStatus, progress: Double, outputs: [URL]) {
        let handler = onUpdate
        Task { @MainActor in handler(jobID, status, progress, outputs) }
    }
}
