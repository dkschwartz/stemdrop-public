import Foundation
import AppKit

/// Which of the two top-level tabs is showing.
enum MainTab: Hashable {
    case split
    case cleanup
}

/// Owns the published job list the UI renders and drives it through a
/// serial `JobQueue`.
@MainActor
final class AppState: ObservableObject {
    @Published var jobs: [AudioJob] = []
    /// Songs dropped in but not yet split. Nothing runs until SPLIT is clicked.
    @Published var staged: [URL] = []
    /// Vocal stems dropped in but not yet cleaned. Nothing runs until CLEAN is clicked.
    @Published var stagedCleanup: [URL] = []
    /// Which tab (Split / Vocal Cleanup) is currently showing.
    @Published var activeTab: MainTab = .split
    /// True while any job is queued or running (from the SPLIT click until
    /// the last job of the batch finishes). Derived, so it can never get stuck.
    var isSplitting: Bool { jobs.contains { $0.status.isActive } }

    /// NSSound must stay retained while it plays, or it is deallocated silently.
    private var currentSound: NSSound?

    /// Shown in the UI after a batch finishes: "SUCCESS! Exported to …".
    @Published var lastResult: BatchResult?

    struct BatchResult: Equatable {
        let succeeded: Int
        let failed: Int
        let folders: [URL]
    }

    private func playSFX(_ name: String) {
        guard prefs.playSound, let sound = NSSound(named: NSSound.Name(name)) else { return }
        currentSound?.stop()
        sound.volume = 1.0
        currentSound = sound
        sound.play()
    }

    let prefs: AppPreferences
    let modelManager: ModelManager

    /// Same engine instance serves as both `StemSeparator` and `VocalCleaner`.
    private let engineRunner = PythonEngineRunner()

    private lazy var jobQueue: JobQueue = JobQueue(
        prefs: prefs,
        modelManager: modelManager,
        converter: AudioConverter(),
        separator: engineRunner,
        cleaner: engineRunner,
        exporter: AudioExporter(),
        onUpdate: { [weak self] jobID, status, progress, outputs in
            self?.updateJob(id: jobID, status: status, progress: progress, outputs: outputs)
        }
    )

    private nonisolated(unsafe) var openURLsObserver: NSObjectProtocol?

    init(prefs: AppPreferences = AppPreferences(), modelManager: ModelManager? = nil) {
        self.prefs = prefs
        self.modelManager = modelManager ?? ModelManager(preferences: prefs)

        let pendingURLs = AppDelegate.pendingOpenURLs
        AppDelegate.pendingOpenURLs.removeAll()

        openURLsObserver = NotificationCenter.default.addObserver(
            forName: .stemDropOpenURLs,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let urls = notification.userInfo?["urls"] as? [URL] else { return }
            Task { @MainActor in
                self?.handleOpenedFiles(urls: urls)
            }
        }

        if !pendingURLs.isEmpty {
            handleOpenedFiles(urls: pendingURLs)
        }
    }

    deinit {
        if let openURLsObserver {
            NotificationCenter.default.removeObserver(openURLsObserver)
        }
    }

    /// Files opened from Finder / the Dock land in whichever tab is showing.
    func handleOpenedFiles(urls: [URL]) {
        switch activeTab {
        case .split: handleDrop(urls: urls)
        case .cleanup: handleCleanupDrop(urls: urls)
        }
    }

    /// Dropping only stages the songs; `split()` starts the work.
    func handleDrop(urls: [URL]) {
        for url in urls where !staged.contains(url) {
            staged.append(url)
        }
    }

    func removeStaged(_ url: URL) {
        staged.removeAll { $0 == url }
    }

    func clearStaged() {
        staged.removeAll()
    }

    /// Dropping only stages the vocal stems; `cleanVocals()` starts the work.
    func handleCleanupDrop(urls: [URL]) {
        for url in urls where !stagedCleanup.contains(url) {
            stagedCleanup.append(url)
        }
    }

    func removeStagedCleanup(_ url: URL) {
        stagedCleanup.removeAll { $0 == url }
    }

    /// SPLIT button: enqueue every staged song with the current stem selection.
    func split() {
        guard !prefs.selectedStems.isEmpty, !staged.isEmpty else { return }
        let urls = staged
        staged.removeAll()
        lastResult = nil
        playSFX("Pop")      // start SFX

        for url in urls {
            let job = AudioJob(
                id: UUID(),
                sourceURL: url,
                stems: prefs.selectedStems,
                status: .queued,
                progress: 0,
                outputs: []
            )
            jobs.append(job)
            let queue = jobQueue
            Task { await queue.enqueue(job) }
        }
    }

    /// CLEAN button: enqueue every staged vocal stem with the current cleanup settings.
    func cleanVocals() {
        guard !stagedCleanup.isEmpty else { return }
        let urls = stagedCleanup
        stagedCleanup.removeAll()
        lastResult = nil
        playSFX("Pop")      // start SFX

        for url in urls {
            let job = AudioJob(
                id: UUID(),
                sourceURL: url,
                stems: [.vocals],
                status: .queued,
                progress: 0,
                outputs: [],
                kind: .cleanup,
                cleanup: prefs.cleanupSettings
            )
            jobs.append(job)
            let queue = jobQueue
            Task { await queue.enqueue(job) }
        }
    }

    private func updateJob(id: UUID, status: JobStatus, progress: Double, outputs: [URL]) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        // A finished job is final: a straggling progress update must not
        // flip it back to "separating" and leave the batch looking stuck.
        guard jobs[index].status.isActive else { return }
        let wasSplitting = isSplitting
        jobs[index].status = status
        jobs[index].progress = progress
        if !outputs.isEmpty {
            jobs[index].outputs = outputs
        }
        if wasSplitting && !isSplitting {
            playSFX("Hero")     // end SFX — batch finished
            let done = jobs.filter { $0.status == .done }
            var folders: [URL] = []
            for job in done {
                if let folder = job.outputs.first?.deletingLastPathComponent(), !folders.contains(folder) {
                    folders.append(folder)
                }
            }
            lastResult = BatchResult(
                succeeded: done.count,
                failed: jobs.count - done.count,
                folders: folders
            )
        }
    }
}
