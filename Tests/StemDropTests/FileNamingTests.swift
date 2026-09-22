import XCTest
@testable import StemDrop

final class FileNamingTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/Users/test/Music/Song.mp3")

    func testDashStyleNoConflict() {
        let url = FileNaming.outputURL(
            source: source,
            stem: .drums,
            style: .dash,
            conflict: .number,
            format: .wav,
            fileExists: { _ in false }
        )
        XCTAssertEqual(url.lastPathComponent, "Song - Drums.wav")
    }

    func testBracketStyleNoConflict() {
        let url = FileNaming.outputURL(
            source: source,
            stem: .drums,
            style: .bracket,
            conflict: .number,
            format: .wav,
            fileExists: { _ in false }
        )
        XCTAssertEqual(url.lastPathComponent, "Song [Drums].wav")
    }

    func testNumberingToThree() {
        let existing: Set<String> = [
            "Song - Drums.wav",
            "Song - Drums 2.wav"
        ]
        let url = FileNaming.outputURL(
            source: source,
            stem: .drums,
            style: .dash,
            conflict: .number,
            format: .wav,
            fileExists: { existing.contains($0.lastPathComponent) }
        )
        XCTAssertEqual(url.lastPathComponent, "Song - Drums 3.wav")
    }

    func testSourceWithDotsInName() {
        let dottedSource = URL(fileURLWithPath: "/Users/test/Music/my.song.v2.mp3")
        let url = FileNaming.outputURL(
            source: dottedSource,
            stem: .vocals,
            style: .dash,
            conflict: .number,
            format: .wav,
            fileExists: { _ in false }
        )
        XCTAssertEqual(url.lastPathComponent, "my.song.v2 - Vocals.wav")
    }

    func testReplacePolicyReturnsUnnumberedURLEvenIfFileExists() {
        let url = FileNaming.outputURL(
            source: source,
            stem: .bass,
            style: .dash,
            conflict: .replace,
            format: .wav,
            fileExists: { _ in true }
        )
        XCTAssertEqual(url.lastPathComponent, "Song - Bass.wav")
    }

    func testAskPolicyReturnsUnnumberedURLEvenIfFileExists() {
        let url = FileNaming.outputURL(
            source: source,
            stem: .bass,
            style: .dash,
            conflict: .ask,
            format: .wav,
            fileExists: { _ in true }
        )
        XCTAssertEqual(url.lastPathComponent, "Song - Bass.wav")
    }

    func testDefaultFormatIsAIFF() {
        let url = FileNaming.outputURL(
            source: source,
            stem: .drums,
            style: .dash,
            conflict: .number,
            fileExists: { _ in false }
        )
        XCTAssertEqual(url.lastPathComponent, "Song - Drums.aiff")
    }

    func testMP3Extension() {
        let url = FileNaming.outputURL(
            source: source,
            stem: .drums,
            style: .dash,
            conflict: .number,
            format: .mp3,
            fileExists: { _ in false }
        )
        XCTAssertEqual(url.lastPathComponent, "Song - Drums.mp3")
    }

    func testExplicitDirectoryOverridesSourceFolder() {
        let explicitDir = URL(fileURLWithPath: "/Users/test/Music/Song STEM SPLIT", isDirectory: true)
        let url = FileNaming.outputURL(
            source: source,
            stem: .drums,
            style: .dash,
            conflict: .number,
            format: .wav,
            directory: explicitDir,
            fileExists: { _ in false }
        )
        XCTAssertEqual(url.deletingLastPathComponent().path, explicitDir.path)
        XCTAssertEqual(url.lastPathComponent, "Song - Drums.wav")
    }

    // MARK: - Cleanup label

    func testCleanLabelDash() {
        let vocalStem = URL(fileURLWithPath: "/Users/test/Music/Song - Vocals.wav")
        let url = FileNaming.outputURL(
            source: vocalStem,
            label: "Vocals CLEAN",
            style: .dash,
            conflict: .number,
            format: .wav,
            baseName: FileNaming.songBaseName(fromStem: vocalStem),
            fileExists: { _ in false }
        )
        XCTAssertEqual(url.lastPathComponent, "Song - Vocals CLEAN.wav")
    }

    func testCleanLabelBracket() {
        let vocalStem = URL(fileURLWithPath: "/Users/test/Music/Song [Vocals].wav")
        let url = FileNaming.outputURL(
            source: vocalStem,
            label: "Vocals CLEAN",
            style: .bracket,
            conflict: .number,
            format: .wav,
            baseName: FileNaming.songBaseName(fromStem: vocalStem),
            fileExists: { _ in false }
        )
        XCTAssertEqual(url.lastPathComponent, "Song [Vocals CLEAN].wav")
    }

    func testCleanLabelNumbering() {
        let vocalStem = URL(fileURLWithPath: "/Users/test/Music/Song - Vocals.wav")
        let existing: Set<String> = ["Song - Vocals CLEAN.wav"]
        let url = FileNaming.outputURL(
            source: vocalStem,
            label: "Vocals CLEAN",
            style: .dash,
            conflict: .number,
            format: .wav,
            baseName: FileNaming.songBaseName(fromStem: vocalStem),
            fileExists: { existing.contains($0.lastPathComponent) }
        )
        XCTAssertEqual(url.lastPathComponent, "Song - Vocals CLEAN 2.wav")
    }

    // MARK: - songBaseName

    func testSongBaseNameStripsDashStemSuffix() {
        let url = URL(fileURLWithPath: "/Users/test/Music/Song - Vocals.aiff")
        XCTAssertEqual(FileNaming.songBaseName(fromStem: url), "Song")
    }

    func testSongBaseNameStripsBracketStemSuffix() {
        let url = URL(fileURLWithPath: "/Users/test/Music/Song [Vocals].wav")
        XCTAssertEqual(FileNaming.songBaseName(fromStem: url), "Song")
    }

    func testSongBaseNameStripsDashStemSuffixWithConflictNumber() {
        let url = URL(fileURLWithPath: "/Users/test/Music/Song - Vocals 2.wav")
        XCTAssertEqual(FileNaming.songBaseName(fromStem: url), "Song")
    }

    func testSongBaseNameWithDotsInName() {
        let url = URL(fileURLWithPath: "/Users/test/Music/my.song.v2 - Vocals.mp3")
        XCTAssertEqual(FileNaming.songBaseName(fromStem: url), "my.song.v2")
    }

    func testSongBaseNameFallsBackWhenNoStemSuffix() {
        let url = URL(fileURLWithPath: "/Users/test/Music/Random.wav")
        XCTAssertEqual(FileNaming.songBaseName(fromStem: url), "Random")
    }
}
