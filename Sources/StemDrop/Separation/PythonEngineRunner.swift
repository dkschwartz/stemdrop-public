import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Non-isolated box used only to hand a `Process` reference into a
/// `@Sendable` cancellation closure. The process itself is only ever
/// touched from the `Process`-owned callback queues, never concurrently
/// with the code that creates/reads this box.
private final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Accumulates stdout bytes into lines, parses engine JSON events, and
/// resolves the async continuation once the process exits.
private final class EngineOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var stems: [StemType: URL] = [:]
    private var errorMessage: String?

    func appendStdout(_ data: Data, progress: @escaping @Sendable (Double) -> Void) {
        guard let text = String(data: data, encoding: .utf8) else { return }

        lock.lock()
        buffer += text
        var lines = buffer.components(separatedBy: "\n")
        buffer = lines.removeLast()
        lock.unlock()

        for line in lines {
            guard let event = JSONLinesParser.parse(line) else { continue }
            handle(event, progress: progress)
        }
    }

    /// Called once stdout has reached EOF; the engine may exit without a
    /// trailing newline, leaving one unparsed line sitting in `buffer`.
    func flushRemaining(progress: @escaping @Sendable (Double) -> Void) {
        lock.lock()
        let remaining = buffer
        buffer = ""
        lock.unlock()

        guard let event = JSONLinesParser.parse(remaining) else { return }
        handle(event, progress: progress)
    }

    private func handle(_ event: EngineEvent, progress: @escaping @Sendable (Double) -> Void) {
        switch event {
        case .loading, .done:
            break
        case .progress(let fraction):
            progress(fraction)
        case .stem(let type, let url):
            lock.lock()
            stems[type] = url
            lock.unlock()
        case .error(let message):
            lock.lock()
            errorMessage = message
            lock.unlock()
        }
    }

    func finish(exitCode: Int32) throws -> [StemType: URL] {
        lock.lock()
        let finalStems = stems
        let message = errorMessage
        lock.unlock()

        if let message {
            Log.engine("engine reported error: \(message)")
            throw StemDropError.separationFailed
        }
        if exitCode != 0 {
            throw StemDropError.separationFailed
        }
        return finalStems
    }
}

/// Fires a completion callback exactly once, after BOTH the process has
/// terminated AND stdout has reached EOF have been observed (they arrive on
/// independent callback queues, in either order).
private final class CompletionGate: @unchecked Sendable {
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

/// Tracks every child `Process` currently in flight so they can all be
/// force-killed together (app quit, orphan sweep) even if their individual
/// completion handlers never fire.
private final class LiveProcessRegistry: @unchecked Sendable {
    static let shared = LiveProcessRegistry()

    private let lock = NSLock()
    private var processes: Set<Process> = []

    private init() {}

    func add(_ process: Process) {
        lock.lock()
        processes.insert(process)
        lock.unlock()
    }

    func remove(_ process: Process) {
        lock.lock()
        processes.remove(process)
        lock.unlock()
    }

    /// Sends SIGTERM to every live process (and its process group), then
    /// waits up to `timeout` for them to actually exit.
    func terminateAll(timeout: TimeInterval = 2) {
        lock.lock()
        let snapshot = processes
        lock.unlock()

        for process in snapshot {
            PythonEngineRunner.terminate(process: process)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let stillRunning = processes.contains { $0.isRunning }
            lock.unlock()
            if !stillRunning { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

final class PythonEngineRunner: StemSeparator, VocalCleaner, Sendable {
    private let pythonPath: URL

    init(pythonPath: URL? = nil) {
        self.pythonPath = pythonPath ?? Self.resolvePythonPath()
    }

    /// Engine location precedence: bundled app resources → dev override
    /// env var → package-relative Resources dir (for `swift run`).
    static func resolvePythonPath() -> URL {
        EnginePaths.pythonExecutable()
    }

    /// Sends SIGTERM to the process's group (so any grandchildren it
    /// spawned die too — see `os.setpgrp()` in `__main__.py`) and to the
    /// process itself, ignoring errors (e.g. it already exited).
    static func terminate(process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        _ = kill(-pid, SIGTERM)
        _ = kill(pid, SIGTERM)
    }

    /// Force-terminates every in-flight engine process. Call on app quit
    /// and as an orphan sweep; waits up to 2 s for exits to be observed.
    static func terminateAll() {
        LiveProcessRegistry.shared.terminateAll()
    }

    func separate(
        inputWAV: URL,
        stems: Set<StemType>,
        workDir: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [StemType: URL] {
        let stemsArg = stems.map(\.rawValue).sorted().joined(separator: ",")

        let arguments = [
            "-m", "stemdrop_engine",
            "--input", inputWAV.path,
            "--out", workDir.path,
            "--stems", stemsArg,
            // "auto": engine picks htdemucs_ft (best quality), or htdemucs_6s
            // only when guitar/piano is requested.
            "--model", "auto",
            "--device", "mps"
        ]

        return try await runEngine(arguments: arguments, progress: progress)
    }

    func clean(
        inputWAV: URL,
        settings: CleanupSettings,
        workDir: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let arguments = [
            "-m", "stemdrop_engine.cleanup",
            "--input", inputWAV.path,
            "--out", workDir.path
        ] + settings.engineArguments + ["--device", "mps"]

        let result = try await runEngine(arguments: arguments, progress: progress)
        guard let vocalsURL = result[.vocals] else {
            throw StemDropError.separationFailed
        }
        return vocalsURL
    }

    private func runEngine(
        arguments: [String],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [StemType: URL] {
        let process = Process()
        process.executableURL = pythonPath
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["STEMDROP_MODEL_DIR"] = ModelManager.modelDir.path
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = EngineOutputCollector()
        let processBox = UncheckedBox(process)

        LiveProcessRegistry.shared.add(process)

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                Log.engine(String(line))
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[StemType: URL], Error>) in
                let resumeLock = NSLock()
                var resumed = false

                func resumeOnce(_ body: () throws -> [StemType: URL]) {
                    resumeLock.lock()
                    guard !resumed else {
                        resumeLock.unlock()
                        return
                    }
                    resumed = true
                    resumeLock.unlock()
                    do {
                        continuation.resume(returning: try body())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }

                let gate = CompletionGate { exitCode in
                    LiveProcessRegistry.shared.remove(process)
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    resumeOnce { try collector.finish(exitCode: exitCode) }
                }

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        collector.flushRemaining(progress: progress)
                        gate.markStdoutEOF()
                        return
                    }
                    collector.appendStdout(data, progress: progress)
                }

                process.terminationHandler = { finishedProcess in
                    gate.markTerminated(exitCode: finishedProcess.terminationStatus)
                }

                do {
                    try process.run()
                } catch {
                    LiveProcessRegistry.shared.remove(process)
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    resumeOnce { throw StemDropError.separationFailed }
                }
            }
        } onCancel: {
            let runningProcess = processBox.value
            if runningProcess.isRunning {
                PythonEngineRunner.terminate(process: runningProcess)
            }
        }
    }
}
