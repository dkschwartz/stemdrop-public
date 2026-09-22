import Foundation

/// Seam so `JobQueue` doesn't need to depend on the concrete
/// `ModelManager` (which owns a shared on-disk model directory with no
/// other injectable surface) — tests can supply a no-op fake instead.
protocol ModelInstalling: Sendable {
    func ensureInstalled() async throws
}

/// Accumulates model-download stdout events, guarded by a lock since the
/// pipe's `readabilityHandler` and the process's `terminationHandler` fire
/// on independent queues.
private final class DownloadOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var sawDone = false
    private var errorMessage: String?

    func appendStdout(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        buffer += text
        var lines = buffer.components(separatedBy: "\n")
        buffer = lines.removeLast()
        lock.unlock()
        for line in lines {
            handle(line)
        }
    }

    /// Called once stdout has reached EOF; parses any partial trailing
    /// line left in the buffer.
    func flushRemaining() {
        lock.lock()
        let remaining = buffer
        buffer = ""
        lock.unlock()
        handle(remaining)
    }

    private func handle(_ line: String) {
        guard let event = JSONLinesParser.parse(line) else { return }
        switch event {
        case .done:
            lock.lock()
            sawDone = true
            lock.unlock()
        case .error(let message):
            lock.lock()
            errorMessage = message
            lock.unlock()
        default:
            break
        }
    }

    func finish(exitCode: Int32) throws {
        lock.lock()
        let done = sawDone
        let message = errorMessage
        lock.unlock()

        if let message {
            Log.engine("model download error: \(message)")
            throw StemDropError.modelDownloadFailed
        }
        guard done, exitCode == 0 else {
            throw StemDropError.modelDownloadFailed
        }
    }
}

/// Fires a completion callback exactly once, after BOTH the process has
/// terminated AND stdout has reached EOF have been observed (they arrive on
/// independent callback queues, in either order).
private final class DownloadCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = false
    private var stdoutEOF = false
    private var exitCode: Int32 = 0
    private var fired = false
    private let onComplete: (Int32) -> Void

    init(onComplete: @escaping (Int32) -> Void) {
        self.onComplete = onComplete
    }

    func markTerminated(exitCode: Int32) {
        lock.lock()
        terminated = true
        self.exitCode = exitCode
        fire()
    }

    func markStdoutEOF() {
        lock.lock()
        stdoutEOF = true
        fire()
    }

    /// Must be called with `lock` held; always unlocks before returning.
    private func fire() {
        guard terminated, stdoutEOF, !fired else {
            lock.unlock()
            return
        }
        fired = true
        let code = exitCode
        lock.unlock()
        onComplete(code)
    }
}

@MainActor
final class ModelManager: ObservableObject, ModelInstalling {
    enum State: Equatable {
        case unknown
        case installed
        case downloading
        case failed(String)
    }

    @Published var state: State = .unknown

    private let preferences: AppPreferences

    nonisolated static let modelDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/StemDrop/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    /// Bump when the required model set changes. Revision 2 adds the
    /// quality model `htdemucs_ft` (SPEC.md quality change, 2026-09-19).
    static let currentModelRevision = 2

    func ensureInstalled() async throws {
        let dirEmpty = (try? FileManager.default.contentsOfDirectory(atPath: Self.modelDir.path).isEmpty) ?? true
        let needsRevision = preferences.modelRevision < Self.currentModelRevision

        guard !preferences.modelInstalled || dirEmpty || needsRevision else {
            state = .installed
            return
        }

        state = .downloading
        do {
            try await runDownload()
            preferences.modelInstalled = true
            preferences.modelRevision = Self.currentModelRevision
            state = .installed
        } catch {
            state = .failed(StemDropError.modelDownloadFailed.errorDescription ?? "")
            throw StemDropError.modelDownloadFailed
        }
    }

    private func runDownload() async throws {
        let pythonPath = PythonEngineRunner.resolvePythonPath()

        let process = Process()
        process.executableURL = pythonPath
        process.arguments = ["-m", "stemdrop_engine.download_model"]

        var environment = ProcessInfo.processInfo.environment
        environment["STEMDROP_MODEL_DIR"] = Self.modelDir.path
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                Log.engine(String(line))
            }
        }

        let collector = DownloadOutputCollector()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeLock = NSLock()
            var resumed = false

            func resumeOnce(_ body: () throws -> Void) {
                resumeLock.lock()
                guard !resumed else {
                    resumeLock.unlock()
                    return
                }
                resumed = true
                resumeLock.unlock()
                do {
                    try body()
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            let gate = DownloadCompletionGate { exitCode in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                resumeOnce { try collector.finish(exitCode: exitCode) }
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    collector.flushRemaining()
                    gate.markStdoutEOF()
                    return
                }
                collector.appendStdout(data)
            }

            process.terminationHandler = { finishedProcess in
                gate.markTerminated(exitCode: finishedProcess.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                resumeOnce { throw StemDropError.modelDownloadFailed }
            }
        }
    }
}
