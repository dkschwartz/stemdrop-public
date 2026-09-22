import XCTest
@testable import StemDrop

@MainActor
final class OutputLocationTests: XCTestCase {
    private var root: URL!
    private var defaultsSuite: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "StemDropTests-\(UUID().uuidString)"
        defaultsSuite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        defaultsSuite.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makePrefs() -> AppPreferences {
        AppPreferences(defaults: defaultsSuite)
    }

    func testRootModeCreatesSongStemSplitFolder() throws {
        let prefs = makePrefs()
        prefs.outputMode = .root
        prefs.outputRootPath = root.path

        let source = root.appendingPathComponent("My Song.mp3")
        FileManager.default.createFile(atPath: source.path, contents: Data([0x00]))

        let folder = try OutputLocation.folder(for: source, prefs: prefs)

        XCTAssertEqual(folder.lastPathComponent, "My Song STEM SPLIT")
        XCTAssertEqual(folder.deletingLastPathComponent().path, root.path)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testSameFolderModeUsesSourceFolder() throws {
        let prefs = makePrefs()
        prefs.outputMode = .sameFolder
        prefs.outputRootPath = root.path

        let sourceFolder = root.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let source = sourceFolder.appendingPathComponent("Track.wav")
        FileManager.default.createFile(atPath: source.path, contents: Data([0x00]))

        let folder = try OutputLocation.folder(for: source, prefs: prefs)

        XCTAssertEqual(folder.path, sourceFolder.path)
    }

    func testRootModeFallsBackToSourceFolderWhenRootMissing() throws {
        let prefs = makePrefs()
        prefs.outputMode = .root
        prefs.outputRootPath = root.appendingPathComponent("Does Not Exist").path

        let source = root.appendingPathComponent("Fallback Song.wav")
        FileManager.default.createFile(atPath: source.path, contents: Data([0x00]))

        let folder = try OutputLocation.folder(for: source, prefs: prefs)

        XCTAssertEqual(folder.deletingLastPathComponent().path, root.path)
        XCTAssertEqual(folder.lastPathComponent, "Fallback Song STEM SPLIT")
    }

    // MARK: - cleanupFolder

    func testCleanupFolderReturnsParentWhenNamedStemSplit() throws {
        let prefs = makePrefs()
        prefs.outputMode = .root
        prefs.outputRootPath = root.path

        let stemSplitFolder = root.appendingPathComponent("My Song STEM SPLIT", isDirectory: true)
        try FileManager.default.createDirectory(at: stemSplitFolder, withIntermediateDirectories: true)
        let source = stemSplitFolder.appendingPathComponent("My Song - Vocals.wav")
        FileManager.default.createFile(atPath: source.path, contents: Data([0x00]))

        let folder = try OutputLocation.cleanupFolder(for: source, prefs: prefs)

        XCTAssertEqual(folder.path, stemSplitFolder.path)
    }

    func testCleanupFolderFallsBackToRootModeFolderWhenParentIsNotStemSplit() throws {
        let prefs = makePrefs()
        prefs.outputMode = .root
        prefs.outputRootPath = root.path

        let source = root.appendingPathComponent("My Song - Vocals.aiff")
        FileManager.default.createFile(atPath: source.path, contents: Data([0x00]))

        let folder = try OutputLocation.cleanupFolder(for: source, prefs: prefs)

        XCTAssertEqual(folder.lastPathComponent, "My Song STEM SPLIT")
        XCTAssertEqual(folder.deletingLastPathComponent().path, root.path)
    }
}
