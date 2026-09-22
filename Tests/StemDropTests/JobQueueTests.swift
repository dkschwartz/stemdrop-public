import XCTest
@testable import StemDrop

// MARK: - Fakes

private struct FakeConverter: AudioConverting {
    func toEngineWAV(_ src: URL, into dir: URL) async throws -> URL {
        dir.appendingPathComponent("input.wav")
    }
}

private struct FakeModelInstalling: ModelInstalling {
    func ensureInstalled() async throws {}
}

/// Tracks call order across jobs so tests can assert strict sequencing.
private actor CallRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

private final class FakeSeparator: StemSeparator, @unchecked Sendable {
    var shouldThrow = false
    let recorder: CallRecorder?

    init(recorder: CallRecorder? = nil) {
        self.recorder = recorder
    }

    func separate(
        inputWAV: URL,
        stems: Set<StemType>,
        workDir: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> [StemType: URL] {
        if let recorder {
            await recorder.record("start:\(inputWAV.lastPathComponent)")
        }
        progress(0.5)
        // Yield so a concurrently-enqueued second job would have a chance
        // to start here if the queue were (incorrectly) running jobs in parallel.
        try await Task.sleep(nanoseconds: 20_000_000)
        if shouldThrow {
            throw StemDropError.separationFailed
        }
        var result: [StemType: URL] = [:]
        for stem in stems {
            result[stem] = workDir.appendingPathComponent("\(stem.rawValue).wav")
        }
        if let recorder {
            await recorder.record("end:\(inputWAV.lastPathComponent)")
        }
        return result
    }
}

private struct FakeExporter: AudioExporting {
    func write(stemWAV: URL, to dst: URL, settings: ExportSettings) throws {
        FileManager.default.createFile(atPath: dst.path, contents: Data())
    }
}

private struct FakeCleaner: VocalCleaner {
    func clean(
        inputWAV: URL,
        settings: CleanupSettings,
        workDir: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        progress(0.5)
        return workDir.appendingPathComponent("vocals.wav")
    }
}

// MARK: - Tests

@MainActor
final class JobQueueTests: XCTestCase {
    /// Every fake source/output in this test file lives under one
    /// per-test directory so a run never touches real user files (see
    /// SPEC brief T7d #7 — this used to litter `/tmp` with real stem
    /// WAVs next to literal `/tmp/a.mp3` fakes).
    private var testDir: URL!

    override func setUpWithError() throws {
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testDir)
        testDir = nil
    }

    private func makePrefs() -> AppPreferences {
        let suiteName = "JobQueueTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let prefs = AppPreferences(defaults: defaults)
        // Keep any output-folder creation inside this test's own temp dir.
        prefs.outputRootPath = testDir.path
        return prefs
    }

    private func makeJob(sourceName: String = "song.mp3", stems: Set<StemType> = [.drums]) -> AudioJob {
        AudioJob(
            id: UUID(),
            sourceURL: testDir.appendingPathComponent(sourceName),
            stems: stems,
            status: .queued,
            progress: 0,
            outputs: []
        )
    }

    func testHappyPathYieldsOneOutputPerStemWithDoneStatus() async throws {
        let prefs = makePrefs()
        let modelManager = FakeModelInstalling()
        let stems: Set<StemType> = [.drums, .vocals]
        let job = makeJob(stems: stems)

        var updates: [(JobStatus, [URL])] = []
        let queue = JobQueue(
            prefs: prefs,
            modelManager: modelManager,
            converter: FakeConverter(),
            separator: FakeSeparator(),
            cleaner: FakeCleaner(),
            exporter: FakeExporter(),
            validate: { _ in },
            checkDiskSpace: { _, _ in },
            onUpdate: { _, status, _, outputs in
                updates.append((status, outputs))
            }
        )

        await queue.enqueue(job)

        let finalOutputs = try await waitForTerminalOutputs(updates: { updates })
        XCTAssertEqual(finalOutputs.count, stems.count)
    }

    func testSeparatorThrowingYieldsFailedWithExpectedMessage() async throws {
        let prefs = makePrefs()
        let modelManager = FakeModelInstalling()
        let job = makeJob()

        let separator = FakeSeparator()
        separator.shouldThrow = true

        var updates: [JobStatus] = []
        let queue = JobQueue(
            prefs: prefs,
            modelManager: modelManager,
            converter: FakeConverter(),
            separator: separator,
            cleaner: FakeCleaner(),
            exporter: FakeExporter(),
            validate: { _ in },
            checkDiskSpace: { _, _ in },
            onUpdate: { _, status, _, _ in
                updates.append(status)
            }
        )

        await queue.enqueue(job)

        let failureMessage = try await waitForFailureMessage(updates: { updates })
        XCTAssertEqual(failureMessage, "Stem separation failed.\nTry converting the song to WAV or M4A.")
    }

    func testTwoJobsRunStrictlySequentially() async throws {
        let prefs = makePrefs()
        let modelManager = FakeModelInstalling()
        let recorder = CallRecorder()
        let separator = FakeSeparator(recorder: recorder)

        let jobA = makeJob(sourceName: "a.mp3")
        let jobB = makeJob(sourceName: "b.mp3")

        var doneCount = 0
        let queue = JobQueue(
            prefs: prefs,
            modelManager: modelManager,
            converter: FakeConverter(),
            separator: separator,
            cleaner: FakeCleaner(),
            exporter: FakeExporter(),
            validate: { _ in },
            checkDiskSpace: { _, _ in },
            onUpdate: { _, status, _, _ in
                if case .done = status { doneCount += 1 }
            }
        )

        await queue.enqueue(jobA)
        await queue.enqueue(jobB)

        try await waitUntil { doneCount == 2 }

        let events = await recorder.events
        XCTAssertEqual(events, ["start:input.wav", "end:input.wav", "start:input.wav", "end:input.wav"])
    }

    func testCleanupJobYieldsOneOutputNamedVocalsClean() async throws {
        let prefs = makePrefs()
        let modelManager = FakeModelInstalling()
        let sourceURL = testDir.appendingPathComponent("song.mp3")
        let job = AudioJob(
            id: UUID(),
            sourceURL: sourceURL,
            stems: [.vocals],
            status: .queued,
            progress: 0,
            outputs: [],
            kind: .cleanup,
            cleanup: CleanupSettings()
        )

        var updates: [(JobStatus, [URL])] = []
        let queue = JobQueue(
            prefs: prefs,
            modelManager: modelManager,
            converter: FakeConverter(),
            separator: FakeSeparator(),
            cleaner: FakeCleaner(),
            exporter: FakeExporter(),
            validate: { _ in },
            checkDiskSpace: { _, _ in },
            onUpdate: { _, status, _, outputs in
                updates.append((status, outputs))
            }
        )

        await queue.enqueue(job)

        let finalOutputs = try await waitForTerminalOutputs(updates: { updates })
        XCTAssertEqual(finalOutputs.count, 1)
        let name = finalOutputs[0].lastPathComponent
        XCTAssertTrue(name.hasPrefix("song"))
        XCTAssertTrue(name.contains("Vocals CLEAN"))
    }

    // MARK: - Polling helpers
    // `onUpdate` fires on the main actor asynchronously from the queue's
    // actor-isolated loop, so tests poll briefly instead of assuming a
    // fixed delay.

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func waitForTerminalOutputs(
        timeout: TimeInterval = 2,
        updates: @MainActor () -> [(JobStatus, [URL])]
    ) async throws -> [URL] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let done = updates().last(where: { if case .done = $0.0 { return true } else { return false } }) {
                return done.1
            }
            if Date() > deadline {
                XCTFail("Timed out waiting for .done status")
                return []
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func waitForFailureMessage(
        timeout: TimeInterval = 2,
        updates: @MainActor () -> [JobStatus]
    ) async throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let failure = updates().compactMap({ status -> String? in
                if case .failed(let message) = status { return message }
                return nil
            }).first {
                return failure
            }
            if Date() > deadline {
                XCTFail("Timed out waiting for .failed status")
                return nil
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
