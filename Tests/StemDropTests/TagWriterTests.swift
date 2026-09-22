import XCTest
import AVFoundation
@testable import StemDrop

final class TagWriterTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    private let meta = StemMetadata(
        artist: "Artist Name",
        album: "ISOLATED TRACKS",
        title: "Song - Drums",
        year: "2026"
    )

    // MARK: - MP3: tag is prepended, audio bytes are untouched

    func testMP3PrependKeepsAudioBytesIntact() throws {
        let originalAudio = Data((0..<4096).map { UInt8($0 % 251) })
        let file = dir.appendingPathComponent("stem.mp3")
        try originalAudio.write(to: file)

        try TagWriter.write(meta, to: file, format: .mp3)

        let tagged = try Data(contentsOf: file)
        XCTAssertGreaterThan(tagged.count, originalAudio.count)
        XCTAssertEqual(String(decoding: tagged.prefix(3), as: UTF8.self), "ID3")

        let tagLength = id3TagLength(tagged)
        XCTAssertEqual(tagged.count - tagLength, originalAudio.count)
        XCTAssertEqual(Data(tagged.suffix(from: tagLength)), originalAudio)
    }

    /// 10-byte ID3 header + 4-byte syncsafe payload size.
    private func id3TagLength(_ data: Data) -> Int {
        let sizeBytes = data[6..<10]
        var size = 0
        for byte in sizeBytes {
            size = (size << 7) | Int(byte & 0x7F)
        }
        return 10 + size
    }

    // MARK: - WAV / AIFF: audio still opens, frame count unchanged

    func testWAVTaggingPreservesAudio() throws {
        let file = dir.appendingPathComponent("stem.wav")
        let frames = try makeTone(at: file, bigEndian: false)
        try TagWriter.write(meta, to: file, format: .wav)
        try assertReopens(file, expectedFrames: frames)
        XCTAssertEqual(String(decoding: try Data(contentsOf: file).prefix(4), as: UTF8.self), "RIFF")
    }

    func testAIFFTaggingPreservesAudio() throws {
        let file = dir.appendingPathComponent("stem.aiff")
        let frames = try makeTone(at: file, bigEndian: true)
        try TagWriter.write(meta, to: file, format: .aiff)
        try assertReopens(file, expectedFrames: frames)
        let bytes = try Data(contentsOf: file)
        XCTAssertEqual(String(decoding: bytes.prefix(4), as: UTF8.self), "FORM")
        XCTAssertNotNil(bytes.range(of: Data("ID3 ".utf8)))
    }

    private func makeTone(at url: URL, bigEndian: Bool) throws -> AVAudioFramePosition {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frameCount: AVAudioFrameCount = 4_410
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        for channel in 0..<2 {
            for frame in 0..<Int(frameCount) {
                buffer.floatChannelData![channel][frame] =
                    Float(sin(2.0 * Double.pi * 440.0 * Double(frame) / 44_100.0)) * 0.25
            }
        }
        try file.write(from: buffer)
        return AVAudioFramePosition(frameCount)
    }

    private func assertReopens(_ url: URL, expectedFrames: AVAudioFramePosition) throws {
        let reopened = try AVAudioFile(forReading: url)
        XCTAssertEqual(reopened.length, expectedFrames)
    }
}
